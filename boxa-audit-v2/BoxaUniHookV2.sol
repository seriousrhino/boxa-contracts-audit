// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BOXA_DEAD, BOXA_TICK_SPACING} from "./BoxaUniConstants.sol";
import {BoxaV4TokenV2} from "./BoxaV4TokenV2.sol";
import {BoxaFeeSplitV2 as BoxaFeeSplit} from "./BoxaFeeSplitV2.sol";

/// @title BOXA launch hook, version 2
/// @notice One instance serves every BOXA launch pool on a v4 PoolManager: a BOXA token paired with a
///         quote asset, which is native HYPE or an ERC-20 the owner has allowlisted for new launches.
/// @dev The fee model is BoxaUniHook's, unchanged:
/// - Every swap pays a base fee of 1% of its quote side: 70% to the creator, 30% to BOXA's treasury.
/// - The creator may add an extra tax per side at launch, up to MAX_EXTRA_FEE_PIPS, so a side never
///   pays more than MAX_TOTAL_FEE_PIPS (10%). The treasury takes the pool's `extraCutBps` of it; the
///   rest is split creator / holders / buyback as the creator chose. See BoxaFeeSplitV2.
/// - Fees, holder rewards and buybacks of a pool are all in its quote asset; credits are kept per
///   payee and currency and paid out by pull payments from this hook's ERC-6909 claims.
/// - Only the launcher creates pools and adds their liquidity and nobody can remove it; exact-input
///   swaps only; no hookData is read. Nothing is upgradeable, pausable or mintable.
/// - Owner powers are only these: for future launches, the treasury's cut of extra taxes (at most 10%)
///   and the quote allowlist; rotating the treasury; handing over or renouncing ownership.
/// What differs from BoxaUniHook, by SolidProof finding:
/// - Holder rewards: every holder share, of buys and sells, waits as pending. It is handed to holders
///   only by releaseHolderRewards and claimRewards, only while the PoolManager is locked, and never in
///   a transaction in which an earner's token balance moved (BoxaV4TokenV2 refuses, and the share
///   stays pending). So a share-out always sees the balances the transaction began with: tokens
///   borrowed from any venue, or bought and sold within one transaction, earn nothing. Swaps never
///   release.
/// - Buyback: spends only up to BUYBACK_MAX_DEVIATION_TICKS above a reference price nobody can move
///   within a timestamp and which can rise only MAX_REFERENCE_RISE_TICKS_PER_SECOND; what it cannot
///   spend stays queued. The reference catches up with time alone, so a budget is never stuck.
/// - A buy that does not spend its whole input (a price limit, or the end of the curve) reverts, since
///   its fee was taken on the whole input.
/// - The owner can rotate the treasury in two steps, including the credit it has not yet claimed.
/// - An allowlisted quote asset must pass a test transfer and a supply bound; donations are refused.
contract BoxaUniHookV2 is IHooks, IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /// @notice Base fee on the quote side of every swap: 1%.
    uint256 public constant BASE_FEE_PIPS = BoxaFeeSplit.BASE_FEE_PIPS;
    /// @notice The treasury's share of the base fee: 30%.
    uint256 public constant BASE_TREASURY_BPS = BoxaFeeSplit.BASE_TREASURY_BPS;
    /// @notice The most a side can pay, base included: 10%.
    uint256 public constant MAX_TOTAL_FEE_PIPS = 100_000;
    /// @notice The most a creator's extra tax can be, per side: 9%.
    uint256 public constant MAX_EXTRA_FEE_PIPS = MAX_TOTAL_FEE_PIPS - BASE_FEE_PIPS;
    /// @notice The most the treasury can take of an extra tax: 10%.
    uint256 public constant MAX_EXTRA_CUT_BPS = 1_000;
    /// @notice 100% in basis points.
    uint256 public constant BPS = BoxaFeeSplit.BPS;
    /// @notice How far above the reference price a buyback may push the token (200 ticks: about 2%).
    int256 public constant BUYBACK_MAX_DEVIATION_TICKS = 200;
    /// @notice How fast the reference may follow the price up (1 tick, 0.01%, per second: about 43% per
    ///         hour). It follows the price down at once, which only makes a buyback cheaper.
    uint256 public constant MAX_REFERENCE_RISE_TICKS_PER_SECOND = 1;
    /// @notice Where bought-back tokens go.
    address public constant DEAD = BOXA_DEAD;
    /// @notice Tick spacing of every launch pool.
    int24 public constant TICK_SPACING = BOXA_TICK_SPACING;
    /// @notice Opening tick for native HYPE pools: about 60 HYPE fully diluted, as BOXA v1–v4.
    int24 public constant HYPE_START_TICK = 166_200;
    /// @notice Lowest opening tick of an ERC-20 quote asset; below it a launch needs more liquidity per
    ///         tick than v4 allows.
    int24 public constant MIN_START_TICK = -349_200;
    /// @notice Highest opening tick of an ERC-20 quote asset.
    int24 public constant MAX_START_TICK = 400_000;
    /// @notice The largest raw supply an allowlisted quote asset may have, which keeps reward per
    ///         share far from its cap.
    uint256 public constant MAX_QUOTE_SUPPLY = 1e30;
    /// @notice The owner's test transfer when allowlisting a quote asset, in its raw units. It comes
    ///         straight back. Large enough that a fee of one basis point shows.
    uint256 public constant QUOTE_PROBE_AMOUNT = 1e6;

    /// @dev Packed in four slots; `pools` returns it in the order BoxaUniHook does.
    struct Pool {
        address token;
        uint16 creatorBps;
        uint16 buybackBps;
        uint16 holdersBps;
        uint16 fixedExtraCutBps; // the treasury's cut, copied at registration
        uint24 buyExtraPips;
        address quote;           // address(0) is native HYPE
        uint24 sellExtraPips;
        uint64 launchTime;
        address creator;
        bool quoteIs0;           // the quote asset is currency0 (always true for native HYPE)
        address pendingCreator;
    }

    /// @notice An ERC-20's standing as a quote asset for new launches.
    /// @param allowed Whether new launches may use it.
    /// @param startTick Tokens per quote unit at launch, as a tick.
    struct QuoteAsset {
        bool allowed;
        int24 startTick;
    }

    /// @dev The price a buyback is bounded by: a tick in which a higher value means a dearer token,
    ///      whichever side of the pool the token is on. Updated at most once per timestamp.
    ///      `floor` is the opening price: the launch liquidity has nothing below it, so a sell of almost
    ///      nothing can move the price there for free and must not drag the reference with it.
    struct PriceReference {
        int24 tick;
        uint64 at;
        int24 floor;
    }

    enum Action { Claim, Buyback }

    /// @notice The PoolManager this hook serves.
    IPoolManager public immutable poolManager;
    /// @notice The only address that may create pools and add liquidity.
    address public immutable launcher;

    /// @notice BOXA's address: earns its share of every fee.
    address public treasury;
    /// @notice The address proposed as the next treasury.
    address public pendingTreasury;
    /// @notice May change the settings for future launches, rotate the treasury, and nothing else.
    address public owner;
    /// @notice The address proposed as the next owner.
    address public pendingOwner;
    /// @notice Treasury share of the extra tax, in basis points, for pools registered from now on.
    uint16 public extraCutBps = uint16(MAX_EXTRA_CUT_BPS);
    /// @notice ERC-20 quote assets new launches may use. Native HYPE is always allowed.
    mapping(address => QuoteAsset) public quoteAssets;

    mapping(PoolId => Pool) private poolData;
    /// @dev Creator credits, per payee and currency (address(0) = native HYPE).
    mapping(address => mapping(address => uint256)) private credits;
    /// @notice The treasury's credit per currency. It belongs to whichever address is the treasury.
    mapping(address => uint256) public treasuryCredit;
    /// @notice Quote asset queued for each pool's buyback-and-burn.
    mapping(PoolId => uint256) public buybackQueued;
    /// @notice Quote asset handed to each pool's holders and not yet claimed.
    mapping(PoolId => uint256) public holderRewards;
    /// @notice Holder shares not handed to holders yet.
    mapping(PoolId => uint256) public pendingHolderRewards;
    mapping(PoolId => PriceReference) private priceReferences;
    /// @notice The pool of each BOXA token launched here.
    mapping(address => PoolId) public poolOf;

    /// @notice A pool was registered, its terms fixed for good.
    /// @param id The pool.
    /// @param token Its token.
    /// @param creator Its creator.
    /// @param creatorBps Creator's share of the extra tax after the treasury's cut.
    /// @param buybackBps Buyback's share of it.
    /// @param holdersBps Holders' share of it.
    /// @param buyFeePips Total buy fee, base included.
    /// @param sellFeePips Total sell fee, base included.
    event PoolRegistered(PoolId indexed id, address indexed token, address indexed creator,
        uint16 creatorBps, uint16 buybackBps, uint16 holdersBps, uint24 buyFeePips, uint24 sellFeePips);
    /// @notice The extra tax and the treasury's cut of it, fixed for the pool's life.
    /// @param id The pool.
    /// @param buyExtraPips Extra tax on buys.
    /// @param sellExtraPips Extra tax on sells.
    /// @param extraCutBps The treasury's cut of it.
    event ExtraTaxSet(PoolId indexed id, uint24 buyExtraPips, uint24 sellExtraPips, uint16 extraCutBps);
    /// @notice The pool's quote asset: the currency of its fees and rewards.
    /// @param id The pool.
    /// @param quote address(0) = native HYPE.
    event PoolQuoteAsset(PoolId indexed id, address indexed quote);
    /// @notice The pool went live.
    /// @param id The pool.
    /// @param launchTime The timestamp.
    event PoolLaunchTime(PoolId indexed id, uint64 launchTime);
    /// @notice A swap paid its fee, in the quote asset.
    /// @param id The pool.
    /// @param fee The whole fee.
    /// @param treasuryCredit To the treasury.
    /// @param creatorCredit To the creator.
    /// @param buybackCredit Queued for buyback.
    /// @param holdersCredit The holder share: pending, or to buyback at a launch's first buy, see the
    ///        events below.
    event FeeTaken(PoolId indexed id, uint256 fee, uint256 treasuryCredit, uint256 creatorCredit, uint256 buybackCredit,
        uint256 holdersCredit);
    /// @notice Pending holder share was handed to holders.
    /// @param id The pool.
    /// @param amount The amount.
    event HolderRewardsAdded(PoolId indexed id, uint256 amount);
    /// @notice A holder share went to buyback instead, as there was nobody to pay.
    /// @param id The pool.
    /// @param amount The amount.
    event HolderRewardsRedirected(PoolId indexed id, uint256 amount);
    /// @notice A holder withdrew rewards.
    /// @param id The pool.
    /// @param holder The holder.
    /// @param recipient Who received them.
    /// @param amount The amount.
    event RewardsClaimed(PoolId indexed id, address indexed holder, address indexed recipient, uint256 amount);
    /// @notice A payee withdrew a credit.
    /// @param payee The payee.
    /// @param recipient Who received it.
    /// @param amount The amount.
    /// @param currency address(0) = native HYPE.
    event Claimed(address indexed payee, address indexed recipient, uint256 amount, address currency);
    /// @notice A buyback ran.
    /// @param id The pool.
    /// @param quoteSpent Quote asset spent.
    /// @param tokensBurned Tokens bought and burned.
    event BuybackExecuted(PoolId indexed id, uint256 quoteSpent, uint256 tokensBurned);
    /// @notice A creator proposed a successor.
    /// @param id The pool.
    /// @param creator The creator.
    /// @param proposed The successor.
    event CreatorProposed(PoolId indexed id, address indexed creator, address indexed proposed);
    /// @notice A successor took over a pool's future creator fees.
    /// @param id The pool.
    /// @param previous The previous creator.
    /// @param next The new creator.
    event CreatorTransferred(PoolId indexed id, address indexed previous, address indexed next);
    /// @notice The treasury's cut for future launches changed.
    /// @param previous The old cut.
    /// @param next The new cut.
    event ExtraCutSet(uint16 previous, uint16 next);
    /// @notice A new treasury was proposed.
    /// @param current The treasury now.
    /// @param proposed The proposal.
    event TreasuryProposed(address indexed current, address indexed proposed);
    /// @notice The treasury moved.
    /// @param previous The old address.
    /// @param next The new address.
    event TreasuryTransferred(address indexed previous, address indexed next);
    /// @notice A quote asset's standing changed.
    /// @param quote The asset.
    /// @param allowed Whether new launches may use it.
    /// @param startTick Its opening tick.
    event QuoteAssetSet(address indexed quote, bool allowed, int24 startTick);
    /// @notice A new owner was proposed.
    /// @param previous The owner now.
    /// @param next The proposal.
    event OwnershipTransferStarted(address indexed previous, address indexed next);
    /// @notice Ownership moved.
    /// @param previous The old owner.
    /// @param next The new owner; zero when renounced.
    event OwnershipTransferred(address indexed previous, address indexed next);

    /// @notice The caller is not the PoolManager.
    error NotPoolManager();
    /// @notice The caller is not the launcher.
    error NotLauncher();
    /// @notice A pool or key is unknown or not as required.
    error InvalidPool();
    /// @notice A constructor address was zero.
    error ZeroAddress();
    /// @notice A payout was sent to the zero address.
    error InvalidRecipient();
    /// @notice The three shares don't add up to 100%.
    error InvalidAllocation();
    /// @notice Launch liquidity can never be removed.
    error LiquidityLocked();
    /// @notice Donations would be lost to the locked position.
    error DonationsNotAccepted();
    /// @notice Only exact-input swaps are supported.
    error ExactInputOnly();
    /// @notice A callback this hook does not use.
    error HookNotImplemented();
    /// @notice Nothing is claimable.
    error NothingToClaim();
    /// @notice No budget is queued for this pool's buyback.
    error NoBuybackBudget();
    /// @notice The caller may not do this.
    error NotAuthorized();
    /// @notice A guarded function was re-entered.
    error Reentrant();
    /// @notice The buyback returned less than the caller's minimum.
    error InsufficientOutput();
    /// @notice A fee setting is above its limit.
    error InvalidFee();
    /// @notice The asset is not an allowed quote asset, or can't be one.
    error QuoteNotAllowed();
    /// @notice The asset's supply is above MAX_QUOTE_SUPPLY.
    error QuoteSupplyTooLarge();
    /// @notice The asset's test transfer did not move the exact amount both ways.
    error QuoteTransferMismatch();
    /// @notice The opening tick is off spacing or out of range.
    error InvalidStartTick();
    /// @notice An amount does not fit an int128.
    error AmountTooLarge();
    /// @notice Rewards cannot be released or claimed while the PoolManager is unlocked.
    error ManagerUnlocked();
    /// @notice A buy did not spend its whole input.
    error PartialFill();
    /// @notice The price is above what a buyback may pay now; the budget stays queued.
    error BuybackAboveBound();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier nonReentrant() {
        bool locked;
        assembly ("memory-safe") {
            locked := tload(0)
            tstore(0, 1)
        }
        if (locked) revert Reentrant();
        _;
        assembly ("memory-safe") {
            tstore(0, 0)
        }
    }

    /// @dev Tokens can only be borrowed from the PoolManager while it is unlocked.
    modifier whenManagerLocked() {
        if (poolManager.isUnlocked()) revert ManagerUnlocked();
        _;
    }

    /// @param poolManager_ The PoolManager this hook serves.
    /// @param launcher_ The only address that may create pools.
    /// @param treasury_ The first treasury.
    /// @param owner_ The first owner.
    constructor(IPoolManager poolManager_, address launcher_, address treasury_, address owner_) {
        if (address(poolManager_) == address(0) || launcher_ == address(0) || treasury_ == address(0)
            || owner_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        launcher = launcher_;
        treasury = treasury_;
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        emit ExtraCutSet(0, uint16(MAX_EXTRA_CUT_BPS));
        Hooks.validateHookPermissions(IHooks(address(this)), permissions());
    }

    /// @notice The callbacks this hook uses; its address must encode exactly these flags (0x2AEC).
    /// @return The permissions.
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
            beforeDonate: true,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---- Owner -----------------------------------------------------------------------------

    /// @notice The treasury's cut of extra taxes for pools registered from now on (0–10%).
    /// @param next The new cut, in basis points.
    function setExtraCutBps(uint16 next) external onlyOwner {
        if (next > MAX_EXTRA_CUT_BPS) revert InvalidFee();
        emit ExtraCutSet(extraCutBps, next);
        extraCutBps = next;
    }

    /// @notice Allow or stop an ERC-20 as the quote asset of new launches, with its opening tick.
    ///         Pools already launched are unaffected.
    /// @dev Only plain ERC-20s belong here: no transfer fees, no rebasing, no transfer hooks, no upgrade
    ///      keys. Allowing makes a test transfer of QUOTE_PROBE_AMOUNT from the owner and straight back,
    ///      so the owner must hold and have approved that amount. This catches a transfer fee today; it
    ///      cannot catch rewards, upgrades or later changes, which remain the owner's judgement.
    /// @param quote The asset.
    /// @param allowed Whether new launches may use it.
    /// @param startTick Whole tokens per whole quote unit, as a tick.
    function setQuoteAsset(address quote, bool allowed, int24 startTick) external onlyOwner {
        if (quote == address(0) || quote.code.length == 0) revert QuoteNotAllowed();
        if (startTick % TICK_SPACING != 0 || startTick < MIN_START_TICK || startTick > MAX_START_TICK) revert InvalidStartTick();
        if (allowed) {
            if (IERC20(quote).totalSupply() > MAX_QUOTE_SUPPLY) revert QuoteSupplyTooLarge();
            uint256 before = IERC20(quote).balanceOf(address(this));
            IERC20(quote).safeTransferFrom(msg.sender, address(this), QUOTE_PROBE_AMOUNT);
            if (IERC20(quote).balanceOf(address(this)) - before != QUOTE_PROBE_AMOUNT) revert QuoteTransferMismatch();
            IERC20(quote).safeTransfer(msg.sender, QUOTE_PROBE_AMOUNT);
            if (IERC20(quote).balanceOf(address(this)) != before) revert QuoteTransferMismatch();
        }
        quoteAssets[quote] = QuoteAsset(allowed, startTick);
        emit QuoteAssetSet(quote, allowed, startTick);
    }

    /// @notice First step of handing over ownership.
    /// @param next The proposed owner.
    function transferOwnership(address next) external onlyOwner {
        pendingOwner = next;
        emit OwnershipTransferStarted(msg.sender, next);
    }

    /// @notice The proposed owner takes over.
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
        if (pendingTreasury != address(0)) emit TreasuryProposed(treasury, address(0));
        pendingTreasury = address(0);
    }

    /// @notice First step of moving the treasury.
    /// @param proposed The proposed address; zero cancels a proposal.
    function proposeTreasury(address proposed) external onlyOwner {
        pendingTreasury = proposed;
        emit TreasuryProposed(treasury, proposed);
    }

    /// @notice The proposed address takes over the treasury: its future fees, its buyback trigger and
    ///         its unclaimed credit, so a lost treasury key loses nothing. Only BOXA's own share moves.
    function acceptTreasury() external {
        if (msg.sender != pendingTreasury || msg.sender == address(0)) revert NotAuthorized();
        emit TreasuryTransferred(treasury, msg.sender);
        treasury = msg.sender;
        pendingTreasury = address(0);
    }

    /// @notice Opening tick for a new launch against `quote`; reverts unless the quote asset is allowed.
    /// @param quote The quote asset; address(0) = native HYPE.
    /// @return The tick.
    function startTickOf(address quote) public view returns (int24) {
        if (quote == address(0)) return HYPE_START_TICK;
        QuoteAsset memory q = quoteAssets[quote];
        if (!q.allowed) revert QuoteNotAllowed();
        return q.startTick;
    }

    // ---- Launcher --------------------------------------------------------------------------

    /// @notice Registers a pool before the launcher initializes it, fixing its fee terms for good.
    /// @param key The pool's key.
    /// @param token Its token.
    /// @param creator Its creator.
    /// @param creatorBps Creator's share of the extra tax after the treasury's cut.
    /// @param buybackBps Buyback's share of it.
    /// @param holdersBps Holders' share of it.
    /// @param buyExtraPips Extra tax on buys.
    /// @param sellExtraPips Extra tax on sells.
    function register(PoolKey calldata key, address token, address creator, uint16 creatorBps, uint16 buybackBps,
        uint16 holdersBps, uint24 buyExtraPips, uint24 sellExtraPips) external
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
        if (poolData[id].token != address(0) || PoolId.unwrap(poolOf[token]) != 0) revert InvalidPool();
        uint16 cut = extraCutBps;
        poolData[id] = Pool({token: token, creatorBps: creatorBps, buybackBps: buybackBps, holdersBps: holdersBps,
            fixedExtraCutBps: cut, buyExtraPips: buyExtraPips, quote: quote, sellExtraPips: sellExtraPips, launchTime: 0,
            creator: creator, quoteIs0: quoteIs0, pendingCreator: address(0)});
        poolOf[token] = id;
        emit PoolRegistered(id, token, creator, creatorBps, buybackBps, holdersBps,
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

    // ---- Views -----------------------------------------------------------------------------

    /// @notice A pool's terms and state, in BoxaUniHook's order.
    /// @param id The pool.
    /// @return token Its token.
    /// @return quote Its quote asset; address(0) = native HYPE.
    /// @return creator Its creator.
    /// @return pendingCreator The proposed creator.
    /// @return creatorBps Creator's share of the extra tax after the treasury's cut.
    /// @return buybackBps Buyback's share of it.
    /// @return holdersBps Holders' share of it.
    /// @return cutBps The treasury's cut of the extra tax, fixed at registration.
    /// @return buyExtraPips Extra tax on buys.
    /// @return sellExtraPips Extra tax on sells.
    /// @return launchTime When it went live.
    /// @return quoteIs0 Whether the quote asset is currency0.
    function pools(PoolId id) external view returns (address token, address quote, address creator, address pendingCreator,
        uint16 creatorBps, uint16 buybackBps, uint16 holdersBps, uint16 cutBps, uint24 buyExtraPips, uint24 sellExtraPips,
        uint64 launchTime, bool quoteIs0)
    {
        Pool storage p = poolData[id];
        return (p.token, p.quote, p.creator, p.pendingCreator, p.creatorBps, p.buybackBps, p.holdersBps,
            p.fixedExtraCutBps, p.buyExtraPips, p.sellExtraPips, p.launchTime, p.quoteIs0);
    }

    /// @notice What `payee` can claim.
    /// @param payee The payee.
    /// @param currency address(0) = native HYPE.
    /// @return amount The amount.
    function claimable(address payee, address currency) public view returns (uint256 amount) {
        amount = credits[payee][currency];
        if (payee == treasury) amount += treasuryCredit[currency];
    }

    /// @notice The reference a buyback would be bounded by now, as a pool tick.
    /// @param id The pool.
    /// @return The tick.
    function buybackReferenceTick(PoolId id) external view returns (int24) {
        Pool storage p = poolData[id];
        if (p.token == address(0)) revert InvalidPool();
        int256 reference_ = _currentReference(id, p.quoteIs0);
        return int24(p.quoteIs0 ? -reference_ : reference_);
    }

    /// @notice The fee split a launched pool applies to `amount` of its quote asset: a buy's input, or
    ///         a sell's output before the fee (the seller receives amount - fee).
    /// @param id The pool.
    /// @param amount The amount.
    /// @param isBuy Which side.
    /// @return The split.
    function previewSplit(PoolId id, uint256 amount, bool isBuy) external view returns (BoxaFeeSplit.Split memory) {
        Pool storage p = poolData[id];
        if (p.token == address(0)) revert InvalidPool();
        return BoxaFeeSplit.split(amount, isBuy ? p.buyExtraPips : p.sellExtraPips, p.fixedExtraCutBps, p.creatorBps,
            p.holdersBps);
    }

    /// @notice The split a pool launched now with these settings would apply (for the launch form).
    /// @param amount The amount.
    /// @param extraPips The extra tax on that side.
    /// @param creatorBps Creator's share.
    /// @param buybackBps Buyback's share.
    /// @param holdersBps Holders' share.
    /// @return The split.
    function previewLaunchSplit(uint256 amount, uint24 extraPips, uint16 creatorBps, uint16 buybackBps,
        uint16 holdersBps) external view returns (BoxaFeeSplit.Split memory)
    {
        _checkTerms(creatorBps, buybackBps, holdersBps, extraPips, 0);
        return BoxaFeeSplit.split(amount, extraPips, extraCutBps, creatorBps, holdersBps);
    }

    /// @notice Total fee rates of a pool, in millionths of the quote side.
    /// @param id The pool.
    /// @return buyFeePips Buy fee, base included.
    /// @return sellFeePips Sell fee, base included.
    function feePips(PoolId id) external view returns (uint24 buyFeePips, uint24 sellFeePips) {
        Pool storage p = poolData[id];
        if (p.token == address(0)) revert InvalidPool();
        return (uint24(BASE_FEE_PIPS + p.buyExtraPips), uint24(BASE_FEE_PIPS + p.sellExtraPips));
    }

    // ---- Hook callbacks --------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != launcher) revert NotLauncher();
        PoolId id = key.toId();
        Pool storage p = poolData[id];
        if (p.token == address(0) || p.launchTime != 0) revert InvalidPool();
        uint64 launchTime = uint64(block.timestamp);
        p.launchTime = launchTime;
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        priceReferences[id] = PriceReference(p.quoteIs0 ? -tick : tick, launchTime, p.quoteIs0 ? -tick : tick);
        emit PoolLaunchTime(id, launchTime);
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != launcher) revert NotLauncher();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert LiquidityLocked();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert DonationsNotAccepted();
    }

    /// @inheritdoc IHooks
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified >= 0) revert ExactInputOnly();
        PoolId id = key.toId();
        Pool storage p = poolData[id];
        if (p.token == address(0)) revert InvalidPool();
        // The first swap of a timestamp records the price before it moves anything.
        _refreshReference(id, p.quoteIs0);
        // A buy pays its fee from the quote it puts in; a sell pays from its quote output in afterSwap.
        if (params.zeroForOne != p.quoteIs0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        uint256 fee = _takeFee(id, p, uint256(-params.amountSpecified), false, sender == launcher);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_toInt128(fee), 0), 0);
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        Pool storage p = poolData[id];
        if (params.zeroForOne == p.quoteIs0) {
            // The fee was taken on the whole input, so the whole input must have been swapped.
            uint256 asked = uint256(-params.amountSpecified);
            uint256 fee = (asked * (BASE_FEE_PIPS + p.buyExtraPips) - 1) / BoxaFeeSplit.PIPS + 1;
            int128 spent = p.quoteIs0 ? delta.amount0() : delta.amount1();
            if (uint256(int256(-spent)) + fee != asked) revert PartialFill();
            return (IHooks.afterSwap.selector, 0);
        }
        int128 output = p.quoteIs0 ? delta.amount0() : delta.amount1();
        if (output <= 0) return (IHooks.afterSwap.selector, 0);
        uint256 sellFee = _takeFee(id, p, uint256(int256(output)), true, false);
        return (IHooks.afterSwap.selector, _toInt128(sellFee));
    }

    /// @dev Records the fee as this hook's ERC-6909 claim (no transfer during the swap) and credits payees.
    function _takeFee(PoolId id, Pool storage p, uint256 amount, bool isSell, bool firstBuy) private returns (uint256) {
        BoxaFeeSplit.Split memory s = BoxaFeeSplit.split(amount, isSell ? p.sellExtraPips : p.buyExtraPips,
            p.fixedExtraCutBps, p.creatorBps, p.holdersBps);
        if (s.fee == 0) return 0;
        address quote = p.quote;
        poolManager.mint(address(this), _id(quote), s.fee);
        treasuryCredit[quote] += s.treasury;
        credits[p.creator][quote] += s.creator;
        buybackQueued[id] += s.buyback;
        if (s.holders != 0) {
            if (firstBuy) {
                // Nobody holds anything yet at the launch's first buy: its holder share buys back.
                buybackQueued[id] += s.holders;
                emit HolderRewardsRedirected(id, s.holders);
            } else {
                pendingHolderRewards[id] += s.holders;
            }
        }
        emit FeeTaken(id, s.fee, s.treasury, s.creator, s.buyback, s.holders);
        return s.fee;
    }

    /// @dev Leaves the share pending when this transaction moved the token. When it cannot be shared at
    ///      all (almost nothing is held outside the pool) the share buys back instead.
    function _releasePending(PoolId id, Pool storage p) private {
        uint256 amount = pendingHolderRewards[id];
        if (amount == 0) return;
        BoxaV4TokenV2.Distribution result = BoxaV4TokenV2(p.token).distribute(amount);
        if (result == BoxaV4TokenV2.Distribution.Deferred) return;
        pendingHolderRewards[id] = 0;
        if (result == BoxaV4TokenV2.Distribution.Shared) {
            holderRewards[id] += amount;
            emit HolderRewardsAdded(id, amount);
        } else {
            buybackQueued[id] += amount;
            emit HolderRewardsRedirected(id, amount);
        }
    }

    // ---- Buyback price bound ---------------------------------------------------------------

    /// @dev The reference as of now: the last one moved towards the current price, at once when the
    ///      price is lower, and by at most the allowed rise for the time passed when it is higher.
    function _currentReference(PoolId id, bool quoteIs0) private view returns (int256) {
        PriceReference storage stored = priceReferences[id];
        int256 last = stored.tick;
        uint256 elapsed = block.timestamp - stored.at;
        if (elapsed == 0) return last;
        (, int24 tick,,) = poolManager.getSlot0(id);
        int256 current = quoteIs0 ? -int256(tick) : int256(tick);
        if (current < stored.floor) current = stored.floor;
        if (current <= last) return current;
        uint256 rise = elapsed * MAX_REFERENCE_RISE_TICKS_PER_SECOND;
        return uint256(current - last) > rise ? last + int256(rise) : current;
    }

    function _refreshReference(PoolId id, bool quoteIs0) private {
        if (priceReferences[id].at == block.timestamp) return;
        PriceReference storage stored = priceReferences[id];
        (stored.tick, stored.at) = (int24(_currentReference(id, quoteIs0)), uint64(block.timestamp));
    }

    /// @dev The price a buyback may not pass, clamped to what the PoolManager accepts as a limit.
    function _buybackLimit(PoolId id, bool quoteIs0) private view returns (uint160) {
        int256 limit = _currentReference(id, quoteIs0) + BUYBACK_MAX_DEVIATION_TICKS;
        int256 tick = quoteIs0 ? -limit : limit;
        if (tick <= TickMath.MIN_TICK) return TickMath.MIN_SQRT_PRICE + 1;
        if (tick >= TickMath.MAX_TICK) return TickMath.MAX_SQRT_PRICE - 1;
        return TickMath.getSqrtPriceAtTick(int24(tick));
    }

    // ---- Payouts ---------------------------------------------------------------------------

    /// @notice Withdraw the caller's credit in `currency` to `recipient`.
    /// @param currency address(0) = native HYPE.
    /// @param recipient Who receives it.
    function claim(address currency, address recipient) external nonReentrant {
        if (recipient == address(0)) revert InvalidRecipient();
        uint256 amount = credits[msg.sender][currency];
        credits[msg.sender][currency] = 0;
        if (msg.sender == treasury) {
            amount += treasuryCredit[currency];
            treasuryCredit[currency] = 0;
        }
        if (amount == 0) revert NothingToClaim();
        poolManager.unlock(abi.encode(Action.Claim, abi.encode(currency, recipient, amount)));
        emit Claimed(msg.sender, recipient, amount, currency);
    }

    /// @notice Withdraw the caller's holder rewards from one BOXA token, in its pool's quote asset,
    ///         first handing out the pending share unless this transaction moved the token (what the
    ///         caller has already earned is paid either way). Not while unlocked.
    /// @param token The token.
    /// @param recipient Who receives the rewards.
    function claimRewards(address token, address recipient) external nonReentrant whenManagerLocked {
        if (recipient == address(0)) revert InvalidRecipient();
        PoolId id = poolOf[token];
        Pool storage p = poolData[id];
        if (p.token != token || token == address(0)) revert InvalidPool();
        _releasePending(id, p);
        uint256 amount = BoxaV4TokenV2(token).withdraw(msg.sender);
        if (amount == 0) revert NothingToClaim();
        holderRewards[id] -= amount;
        poolManager.unlock(abi.encode(Action.Claim, abi.encode(p.quote, recipient, amount)));
        emit RewardsClaimed(id, msg.sender, recipient, amount);
    }

    /// @notice Hand a pool's waiting holder share to its current holders. Anyone may call it, but not
    ///         while the PoolManager is unlocked. A transaction that moved the token releases nothing
    ///         (no revert) and the share keeps waiting. Swaps do not release, so this has to be called.
    /// @param id The pool.
    function releaseHolderRewards(PoolId id) external nonReentrant whenManagerLocked {
        Pool storage p = poolData[id];
        if (p.token == address(0)) revert InvalidPool();
        _releasePending(id, p);
    }

    /// @notice Spend a pool's queued quote asset on its token, up to the price bound, and burn what is
    ///         bought. What the bound leaves unspent stays queued for a later call.
    /// @dev Anyone may trigger it, with their own minimum output: the price bound protects the budget.
    ///      Reverts with BuybackAboveBound, changing nothing, while the price is above the bound; the
    ///      reference catches up with time alone, with or without trades.
    /// @param key The pool's key.
    /// @param minTokensOut Least the buyback may burn.
    function processBuyback(PoolKey calldata key, uint256 minTokensOut) external nonReentrant {
        PoolId id = key.toId();
        Pool storage p = poolData[id];
        if (p.token == address(0) || address(key.hooks) != address(this)) revert InvalidPool();
        uint256 amount = buybackQueued[id];
        if (amount == 0) revert NoBuybackBudget();
        _refreshReference(id, p.quoteIs0);
        uint160 limit = _buybackLimit(id, p.quoteIs0);
        (uint160 price,,,) = poolManager.getSlot0(id);
        if (p.quoteIs0 ? price <= limit : price >= limit) revert BuybackAboveBound();
        buybackQueued[id] = 0;
        bytes memory result = poolManager.unlock(abi.encode(Action.Buyback, abi.encode(key, p.quoteIs0, amount, limit)));
        (uint256 spent, uint256 burned) = abi.decode(result, (uint256, uint256));
        if (burned < minTokensOut) revert InsufficientOutput();
        if (spent < amount) buybackQueued[id] = amount - spent;
        emit BuybackExecuted(id, spent, burned);
    }

    /// @notice Runs inside this hook's own PoolManager unlock: pays a claim, or swaps and burns a buyback.
    /// @param data The action and its arguments.
    /// @return For a buyback, what it spent and bought.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, bytes memory payload) = abi.decode(data, (Action, bytes));
        if (action == Action.Claim) {
            (address currency, address recipient, uint256 amount) = abi.decode(payload, (address, address, uint256));
            poolManager.burn(address(this), _id(currency), amount);
            poolManager.take(Currency.wrap(currency), recipient, amount);
            return "";
        }
        (PoolKey memory key, bool quoteIs0, uint256 budget, uint160 limit) =
            abi.decode(payload, (PoolKey, bool, uint256, uint160));
        Currency quote = quoteIs0 ? key.currency0 : key.currency1;
        Currency token = quoteIs0 ? key.currency1 : key.currency0;
        poolManager.burn(address(this), quote.toId(), budget);
        // Swaps by the hook itself skip its callbacks: no fee.
        BalanceDelta delta = poolManager.swap(key, SwapParams({zeroForOne: quoteIs0, amountSpecified: -_toInt128(budget),
            sqrtPriceLimitX96: limit}), "");
        uint256 spent = uint256(int256(-(quoteIs0 ? delta.amount0() : delta.amount1())));
        uint256 bought = uint256(int256(quoteIs0 ? delta.amount1() : delta.amount0()));
        if (bought != 0) poolManager.take(token, DEAD, bought);
        // Whatever the swap could not use goes back to the hook's claims.
        if (spent < budget) poolManager.mint(address(this), quote.toId(), budget - spent);
        return abi.encode(spent, bought);
    }

    // ---- Creator handoff -------------------------------------------------------------------

    /// @notice A creator proposes a successor for the pool's future fees.
    /// @param id The pool.
    /// @param proposed The successor; zero cancels a proposal.
    function proposeCreator(PoolId id, address proposed) external {
        Pool storage p = poolData[id];
        if (msg.sender != p.creator || p.token == address(0)) revert NotAuthorized();
        p.pendingCreator = proposed;
        emit CreatorProposed(id, msg.sender, proposed);
    }

    /// @notice Future fees go to the new creator; credits already earned stay with the previous one.
    /// @param id The pool.
    function acceptCreator(PoolId id) external {
        Pool storage p = poolData[id];
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

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
