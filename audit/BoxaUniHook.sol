// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BoxaV4Token} from "./BoxaV4Token.sol";
import {BoxaFeeSplit} from "./BoxaFeeSplit.sol";

/// @notice BOXA launch hook for a v4 PoolManager (built for the official Uniswap one). One instance
///         serves every BOXA launch pool: a BOXA token paired with a quote asset, which is native
///         HYPE or an ERC-20 the owner has allowlisted for new launches (stocks such as wNVDAx, KNTQ…).
///         Based on BoxaV4Hook, with a new fee model and any quote asset:
/// - Every swap pays a base fee of 1% of its quote side: 70% to the creator, 30% to BOXA's treasury.
/// - The creator may add an extra tax per side at launch, up to MAX_EXTRA_FEE_PIPS, so a side never
///   pays more than MAX_TOTAL_FEE_PIPS (10%). The treasury takes the pool's `extraCutBps` of it; the
///   rest is split creator / holders / buyback as the creator chose. See BoxaFeeSplit.
/// - Fees, holder rewards and buybacks of a pool are all in its quote asset; credits are kept per
///   payee and currency and paid out by pull payments from this hook's ERC-6909 claims.
/// - Owner powers are only these, and only for launches still to come: the treasury's cut of extra
///   taxes (`extraCutBps`, at most 10%, copied into each pool when it registers), which ERC-20s may be
///   quote assets (and their opening price), and handing over or renouncing ownership (two-step
///   hand-over). Nothing else: no power over pools, their terms, liquidity, fees earned or any credit.
///   The PoolManager, launcher and treasury are immutable; nothing is upgradeable.
/// Unchanged from BoxaV4Hook: only the launcher creates pools and adds their liquidity and nobody can
/// remove it; the fee is taken from the quote input of a buy and the quote output of a sell, exact-input
/// swaps only; holder rewards (a sell's share waits for the next trade), buyback-and-burn, anti-snipe,
/// creator handoff. No hookData is read, and the fee is a pure function of the swap, so a quote always
/// equals execution.
contract BoxaUniHook is IHooks, IUnlockCallback {
    uint256 public constant BASE_FEE_PIPS = BoxaFeeSplit.BASE_FEE_PIPS;           // 1%
    uint256 public constant BASE_TREASURY_BPS = BoxaFeeSplit.BASE_TREASURY_BPS;   // 30% of the base fee
    uint256 public constant MAX_TOTAL_FEE_PIPS = 100_000;                         // 10% per side, base included
    uint256 public constant MAX_EXTRA_FEE_PIPS = MAX_TOTAL_FEE_PIPS - BASE_FEE_PIPS; // 9%
    uint256 public constant MAX_EXTRA_CUT_BPS = 1_000;                            // treasury share of extra tax: at most 10%
    uint256 public constant BPS = 10_000;
    uint256 public constant ANTI_SNIPE_DURATION = 60 seconds;
    uint256 public constant MAX_SNIPE_BUY = 10_000_000 ether; // 1% of the 1B supply
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 public constant TICK_SPACING = 200;
    /// @notice Opening tick for native HYPE pools: about 60 HYPE fully diluted, as BOXA v1–v4.
    int24 public constant HYPE_START_TICK = 166_200;
    /// @notice Bounds on an ERC-20 quote asset's opening tick (tokens per whole quote unit).
    int24 public constant MIN_START_TICK = -400_000;
    int24 public constant MAX_START_TICK = 400_000;

    struct Pool {
        address token;
        address quote;          // address(0) is native HYPE
        address creator;
        address pendingCreator;
        uint16 creatorBps;
        uint16 buybackBps;
        uint16 holdersBps;
        uint16 extraCutBps;     // snapshot of the treasury's cut at registration
        uint24 buyExtraPips;
        uint24 sellExtraPips;
        uint64 launchTime;
        bool antiSnipe;
        bool quoteIs0;          // the quote asset is currency0 (always true for native HYPE)
    }

    struct QuoteAsset {
        bool allowed;
        int24 startTick;        // tokens per quote unit at launch, as a tick
    }

    enum Action { Claim, Buyback }

    IPoolManager public immutable poolManager;
    address public immutable launcher;
    address public immutable treasury;

    /// @notice May change the three settings for future launches named above, and nothing else.
    address public owner;
    address public pendingOwner;
    /// @notice Treasury share of the extra tax, in basis points, for pools registered from now on.
    uint16 public extraCutBps = uint16(MAX_EXTRA_CUT_BPS);
    /// @notice ERC-20 quote assets new launches may use. Native HYPE is always allowed.
    mapping(address => QuoteAsset) public quoteAssets;

    mapping(PoolId => Pool) public pools;
    /// @notice What each payee can claim, per currency (address(0) = native HYPE).
    mapping(address => mapping(address => uint256)) public claimable;
    /// @notice Quote asset queued for each pool's buyback-and-burn.
    mapping(PoolId => uint256) public buybackQueued;
    /// @notice Quote asset handed to each pool's holders and not yet claimed.
    mapping(PoolId => uint256) public holderRewards;
    /// @notice A sell's holder share, waiting for the next trade on the pool.
    mapping(PoolId => uint256) public pendingHolderRewards;
    /// @notice The pool of each BOXA token launched here.
    mapping(address => PoolId) public poolOf;

    uint256 private entered = 1;

    /// @dev Same shape as BoxaV4Hook's; buyFeePips / sellFeePips are the totals (base + extra).
    event PoolRegistered(PoolId indexed id, address indexed token, address indexed creator,
        uint16 creatorBps, uint16 buybackBps, uint16 holdersBps, bool antiSnipe, uint24 buyFeePips, uint24 sellFeePips);
    /// @notice The extra tax and the treasury's cut of it, fixed for the pool's life.
    event ExtraTaxSet(PoolId indexed id, uint24 buyExtraPips, uint24 sellExtraPips, uint16 extraCutBps);
    /// @notice The pool's quote asset (address(0) = native HYPE): the currency of its fees and rewards.
    event PoolQuoteAsset(PoolId indexed id, address indexed quote);
    /// @dev Same shape as BoxaV4Hook's; amounts are in the pool's quote asset.
    event FeeTaken(PoolId indexed id, uint256 fee, uint256 treasuryCredit, uint256 creatorCredit, uint256 buybackCredit,
        uint256 holdersCredit);
    event HolderRewardsAdded(PoolId indexed id, uint256 amount);
    event RewardsClaimed(PoolId indexed id, address indexed holder, address indexed recipient, uint256 amount);
    /// @dev BoxaV4Hook's shape with the currency appended (address(0) = native HYPE).
    event Claimed(address indexed payee, address indexed recipient, uint256 amount, address currency);
    event BuybackExecuted(PoolId indexed id, uint256 nativeSpent, uint256 tokensBurned);
    event CreatorProposed(PoolId indexed id, address indexed creator, address indexed proposed);
    event CreatorTransferred(PoolId indexed id, address indexed previous, address indexed next);
    event ExtraCutSet(uint16 previous, uint16 next);
    event QuoteAssetSet(address indexed quote, bool allowed, int24 startTick);
    event OwnershipTransferStarted(address indexed previous, address indexed next);
    event OwnershipTransferred(address indexed previous, address indexed next);

    error NotPoolManager();
    error NotLauncher();
    error InvalidPool();
    error InvalidAllocation();
    error LiquidityLocked();
    error ExactInputOnly();
    error AntiSnipeLimit();
    error HookNotImplemented();
    error NothingToClaim();
    error NotAuthorized();
    error Reentrant();
    error InsufficientOutput();
    error InvalidFee();
    error QuoteNotAllowed();
    error InvalidStartTick();
    error AmountTooLarge();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier nonReentrant() {
        if (entered != 1) revert Reentrant();
        entered = 2;
        _;
        entered = 1;
    }

    constructor(IPoolManager poolManager_, address launcher_, address treasury_, address owner_) {
        if (address(poolManager_) == address(0) || launcher_ == address(0) || treasury_ == address(0)
            || owner_ == address(0)) revert InvalidPool();
        poolManager = poolManager_;
        launcher = launcher_;
        treasury = treasury_;
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        emit ExtraCutSet(0, uint16(MAX_EXTRA_CUT_BPS));
        Hooks.validateHookPermissions(IHooks(address(this)), permissions());
    }

    /// @notice The callbacks this hook uses; its address must encode exactly these flags (0x2ACC).
    function permissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---- Owner: settings for future launches only ------------------------------------------

    /// @notice The treasury's cut of extra taxes for pools registered from now on (0–10%).
    function setExtraCutBps(uint16 next) external onlyOwner {
        if (next > MAX_EXTRA_CUT_BPS) revert InvalidFee();
        emit ExtraCutSet(extraCutBps, next);
        extraCutBps = next;
    }

    /// @notice Allow or stop an ERC-20 as the quote asset of new launches, with its opening tick
    ///         (whole tokens per whole quote unit, as a tick). Pools already launched are unaffected.
    /// @dev Only plain ERC-20s belong here: no transfer fees, no rebasing, no transfer hooks. The
    ///      launcher also refuses a quote asset whose transfer delivers less than was sent.
    function setQuoteAsset(address quote, bool allowed, int24 startTick) external onlyOwner {
        if (quote == address(0) || quote.code.length == 0) revert QuoteNotAllowed();
        if (startTick % TICK_SPACING != 0 || startTick < MIN_START_TICK || startTick > MAX_START_TICK) revert InvalidStartTick();
        quoteAssets[quote] = QuoteAsset(allowed, startTick);
        emit QuoteAssetSet(quote, allowed, startTick);
    }

    function transferOwnership(address next) external onlyOwner {
        pendingOwner = next;
        emit OwnershipTransferStarted(msg.sender, next);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner || msg.sender == address(0)) revert NotAuthorized();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Gives up the owner role for good: the settings stay as they are.
    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(msg.sender, address(0));
        owner = address(0);
        pendingOwner = address(0);
    }

    /// @notice Opening tick for a new launch against `quote`; reverts unless the quote asset is allowed.
    function startTickOf(address quote) public view returns (int24) {
        if (quote == address(0)) return HYPE_START_TICK;
        QuoteAsset memory q = quoteAssets[quote];
        if (!q.allowed) revert QuoteNotAllowed();
        return q.startTick;
    }

    // ---- Launcher ------------------------------------------------------------------------

    /// @notice Registers a pool before the launcher initializes it, fixing its fee terms for good.
    function register(PoolKey calldata key, address token, address creator, uint16 creatorBps, uint16 buybackBps,
        uint16 holdersBps, bool antiSnipe, uint24 buyExtraPips, uint24 sellExtraPips) external
    {
        if (msg.sender != launcher) revert NotLauncher();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (key.fee != 0 || key.tickSpacing != TICK_SPACING || address(key.hooks) != address(this)
            || creator == address(0) || token == address(0) || (token != c0 && token != c1)) revert InvalidPool();
        bool quoteIs0 = token == c1;
        address quote = quoteIs0 ? c0 : c1;
        startTickOf(quote); // the quote asset must be allowed now
        _checkTerms(creatorBps, buybackBps, holdersBps, buyExtraPips, sellExtraPips);
        PoolId id = key.toId();
        if (pools[id].token != address(0) || PoolId.unwrap(poolOf[token]) != 0) revert InvalidPool();
        uint16 cut = extraCutBps;
        pools[id] = Pool(token, quote, creator, address(0), creatorBps, buybackBps, holdersBps, cut, buyExtraPips,
            sellExtraPips, 0, antiSnipe, quoteIs0);
        poolOf[token] = id;
        emit PoolRegistered(id, token, creator, creatorBps, buybackBps, holdersBps, antiSnipe,
            uint24(BASE_FEE_PIPS + buyExtraPips), uint24(BASE_FEE_PIPS + sellExtraPips));
        emit ExtraTaxSet(id, buyExtraPips, sellExtraPips, cut);
        emit PoolQuoteAsset(id, quote);
    }

    function _checkTerms(uint16 creatorBps, uint16 buybackBps, uint16 holdersBps, uint24 buyExtraPips, uint24 sellExtraPips)
        private
        pure
    {
        if (uint256(creatorBps) + buybackBps + holdersBps != BPS) revert InvalidAllocation();
        if (buyExtraPips > MAX_EXTRA_FEE_PIPS || sellExtraPips > MAX_EXTRA_FEE_PIPS) revert InvalidFee();
    }

    // ---- Previews ------------------------------------------------------------------------

    /// @notice The fee split a launched pool applies to `amount` of its quote asset: a buy's input, or a
    ///         sell's output before the fee (the seller receives amount - fee).
    function previewSplit(PoolId id, uint256 amount, bool isBuy) external view returns (BoxaFeeSplit.Split memory) {
        Pool storage p = pools[id];
        if (p.token == address(0)) revert InvalidPool();
        return BoxaFeeSplit.split(amount, isBuy ? p.buyExtraPips : p.sellExtraPips, p.extraCutBps, p.creatorBps,
            p.holdersBps);
    }

    /// @notice The split a pool launched now with these settings would apply (for the launch form).
    function previewLaunchSplit(uint256 amount, uint24 extraPips, uint16 creatorBps, uint16 buybackBps,
        uint16 holdersBps) external view returns (BoxaFeeSplit.Split memory)
    {
        _checkTerms(creatorBps, buybackBps, holdersBps, extraPips, 0);
        return BoxaFeeSplit.split(amount, extraPips, extraCutBps, creatorBps, holdersBps);
    }

    /// @notice Total fee rates of a pool, in millionths of the quote side.
    function feePips(PoolId id) external view returns (uint24 buyFeePips, uint24 sellFeePips) {
        Pool storage p = pools[id];
        if (p.token == address(0)) revert InvalidPool();
        return (uint24(BASE_FEE_PIPS + p.buyExtraPips), uint24(BASE_FEE_PIPS + p.sellExtraPips));
    }

    // ---- Hook callbacks ------------------------------------------------------------------

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (sender != launcher) revert NotLauncher();
        Pool storage p = pools[key.toId()];
        if (p.token == address(0) || p.launchTime != 0) revert InvalidPool();
        p.launchTime = uint64(block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != launcher) revert NotLauncher();
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert LiquidityLocked();
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified >= 0) revert ExactInputOnly();
        PoolId id = key.toId();
        Pool storage p = pools[id];
        if (p.token == address(0)) revert InvalidPool();
        // The previous sell's holder share goes to whoever holds now, before this trade moves tokens.
        _releasePending(id, p);
        // A buy pays its fee from the quote it puts in; a sell pays from its quote output in afterSwap.
        if (params.zeroForOne != p.quoteIs0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        uint256 fee = _takeFee(id, p, uint256(-params.amountSpecified), false);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_toInt128(fee), 0), 0);
    }

    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        Pool storage p = pools[id];
        if (params.zeroForOne == p.quoteIs0) {
            int128 tokensOut = p.quoteIs0 ? delta.amount1() : delta.amount0();
            if (p.antiSnipe && sender != launcher && block.timestamp < uint256(p.launchTime) + ANTI_SNIPE_DURATION
                && tokensOut > int128(int256(MAX_SNIPE_BUY))) revert AntiSnipeLimit();
            return (IHooks.afterSwap.selector, 0);
        }
        int128 output = p.quoteIs0 ? delta.amount0() : delta.amount1();
        if (output <= 0) return (IHooks.afterSwap.selector, 0);
        uint256 fee = _takeFee(id, p, uint256(int256(output)), true);
        return (IHooks.afterSwap.selector, _toInt128(fee));
    }

    /// @dev Records the fee as this hook's ERC-6909 claim (no transfer during the swap) and credits payees.
    function _takeFee(PoolId id, Pool storage p, uint256 amount, bool isSell) private returns (uint256) {
        BoxaFeeSplit.Split memory s = BoxaFeeSplit.split(amount, isSell ? p.sellExtraPips : p.buyExtraPips,
            p.extraCutBps, p.creatorBps, p.holdersBps);
        if (s.fee == 0) return 0;
        address quote = p.quote;
        poolManager.mint(address(this), _id(quote), s.fee);
        claimable[treasury][quote] += s.treasury;
        claimable[p.creator][quote] += s.creator;
        buybackQueued[id] += s.buyback;
        if (isSell) pendingHolderRewards[id] += s.holders;
        else _addHolderRewards(id, p.token, s.holders);
        emit FeeTaken(id, s.fee, s.treasury, s.creator, s.buyback, s.holders);
        return s.fee;
    }

    function _releasePending(PoolId id, Pool storage p) private {
        uint256 amount = pendingHolderRewards[id];
        if (amount == 0) return;
        pendingHolderRewards[id] = 0;
        _addHolderRewards(id, p.token, amount);
    }

    /// @dev While almost nothing is held outside the pool there is nobody to pay; the share buys back instead.
    function _addHolderRewards(PoolId id, address token, uint256 amount) private {
        if (amount == 0) return;
        if (BoxaV4Token(token).distribute(amount)) {
            holderRewards[id] += amount;
            emit HolderRewardsAdded(id, amount);
        } else {
            buybackQueued[id] += amount;
        }
    }

    // ---- Payouts -------------------------------------------------------------------------

    /// @notice Withdraw the caller's credit in `currency` (address(0) = native HYPE) to `recipient`.
    function claim(address currency, address recipient) external nonReentrant {
        uint256 amount = claimable[msg.sender][currency];
        if (amount == 0) revert NothingToClaim();
        claimable[msg.sender][currency] = 0;
        poolManager.unlock(abi.encode(Action.Claim, abi.encode(currency, recipient, amount)));
        emit Claimed(msg.sender, recipient, amount, currency);
    }

    /// @notice Withdraw the caller's holder rewards from one BOXA token, in its pool's quote asset.
    function claimRewards(address token, address recipient) external nonReentrant {
        PoolId id = poolOf[token];
        Pool storage p = pools[id];
        if (p.token != token || token == address(0)) revert InvalidPool();
        _releasePending(id, p);
        uint256 amount = BoxaV4Token(token).withdraw(msg.sender);
        if (amount == 0) revert NothingToClaim();
        holderRewards[id] -= amount;
        poolManager.unlock(abi.encode(Action.Claim, abi.encode(p.quote, recipient, amount)));
        emit RewardsClaimed(id, msg.sender, recipient, amount);
    }

    /// @notice Hand a waiting sell share to current holders without a trade.
    function releaseHolderRewards(PoolId id) external nonReentrant {
        Pool storage p = pools[id];
        if (p.token == address(0)) revert InvalidPool();
        _releasePending(id, p);
    }

    /// @notice Spend a pool's queued quote asset on its token and burn what is bought.
    /// @dev Only the pool's creator or the treasury may trigger it, with their own minimum output.
    function processBuyback(PoolKey calldata key, uint256 minTokensOut) external nonReentrant {
        PoolId id = key.toId();
        Pool storage p = pools[id];
        if (p.token == address(0) || address(key.hooks) != address(this)) revert InvalidPool();
        if (msg.sender != p.creator && msg.sender != treasury) revert NotAuthorized();
        uint256 amount = buybackQueued[id];
        if (amount == 0) revert NothingToClaim();
        buybackQueued[id] = 0;
        bytes memory result = poolManager.unlock(abi.encode(Action.Buyback, abi.encode(key, p.quoteIs0, amount)));
        (uint256 spent, uint256 burned) = abi.decode(result, (uint256, uint256));
        if (burned < minTokensOut) revert InsufficientOutput();
        if (spent < amount) buybackQueued[id] = amount - spent;
        emit BuybackExecuted(id, spent, burned);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, bytes memory payload) = abi.decode(data, (Action, bytes));
        if (action == Action.Claim) {
            (address currency, address recipient, uint256 amount) = abi.decode(payload, (address, address, uint256));
            poolManager.burn(address(this), _id(currency), amount);
            poolManager.take(Currency.wrap(currency), recipient, amount);
            return "";
        }
        (PoolKey memory key, bool quoteIs0, uint256 budget) = abi.decode(payload, (PoolKey, bool, uint256));
        Currency quote = quoteIs0 ? key.currency0 : key.currency1;
        Currency token = quoteIs0 ? key.currency1 : key.currency0;
        poolManager.burn(address(this), quote.toId(), budget);
        // Swaps by the hook itself skip its callbacks: no fee and no anti-snipe check.
        BalanceDelta delta = poolManager.swap(key, SwapParams({zeroForOne: quoteIs0, amountSpecified: -_toInt128(budget),
            sqrtPriceLimitX96: quoteIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}), "");
        uint256 spent = uint256(int256(-(quoteIs0 ? delta.amount0() : delta.amount1())));
        uint256 bought = uint256(int256(quoteIs0 ? delta.amount1() : delta.amount0()));
        if (bought != 0) poolManager.take(token, DEAD, bought);
        // Whatever the swap could not use goes back to the hook's claims.
        if (spent < budget) poolManager.mint(address(this), quote.toId(), budget - spent);
        return abi.encode(spent, bought);
    }

    // ---- Creator handoff -----------------------------------------------------------------

    function proposeCreator(PoolId id, address proposed) external {
        Pool storage p = pools[id];
        if (msg.sender != p.creator || p.token == address(0)) revert NotAuthorized();
        p.pendingCreator = proposed;
        emit CreatorProposed(id, msg.sender, proposed);
    }

    /// @notice Future fees go to the new creator; credits already earned stay with the previous one.
    function acceptCreator(PoolId id) external {
        Pool storage p = pools[id];
        if (msg.sender != p.pendingCreator || msg.sender == address(0)) revert NotAuthorized();
        emit CreatorTransferred(id, p.creator, msg.sender);
        p.creator = msg.sender;
        p.pendingCreator = address(0);
    }

    // ---- Helpers ---------------------------------------------------------------------------

    function _id(address currency) private pure returns (uint256) {
        return uint256(uint160(currency));
    }

    function _toInt128(uint256 x) private pure returns (int128) {
        if (x > uint256(uint128(type(int128).max))) revert AmountTooLarge();
        return int128(int256(x));
    }

    // ---- Callbacks this hook does not use --------------------------------------------------

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
