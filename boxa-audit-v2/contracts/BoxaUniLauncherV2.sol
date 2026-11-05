// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BOXA_DEAD, BOXA_SUPPLY, BOXA_TICK_SPACING} from "./BoxaUniConstants.sol";
import {BoxaV4TokenV2} from "./BoxaV4TokenV2.sol";
import {BoxaUniHookV2} from "./BoxaUniHookV2.sol";

/// @title BOXA launcher, version 2
/// @notice Launches a BOXA token in one transaction on BoxaUniHookV2's PoolManager: creates the token,
///         registers and initializes its pool against the chosen quote asset (native HYPE or an
///         allowlisted ERC-20), places the whole supply as single-sided liquidity that can never be
///         removed, and optionally makes the creator's first buy. Keeps no funds, has no owner and
///         no function to touch the liquidity.
/// @dev The opening price is the hook's start tick for the quote asset, in tokens per quote unit. When
///      the quote asset sorts first (always for HYPE) the token is currency1 and its liquidity sits from
///      MIN_TICK up to that tick; otherwise the token is currency0 and its liquidity sits from the
///      inverted tick up to MAX_TICK. Either way the pool opens at the edge of the position, holding
///      only the token.
///      Differs from BoxaUniLauncher: the creator names the owner-set terms they expect (treasury cut,
///      opening tick) and the launch reverts if those changed; the first buy of an anti-snipe launch is
///      capped; tokens are BoxaV4TokenV2; transfers use OpenZeppelin's SafeERC20, which checks for code.
contract BoxaUniLauncherV2 is IUnlockCallback {
    using SafeERC20 for IERC20;

    /// @notice Tick spacing of every launch pool.
    int24 public constant TICK_SPACING = BOXA_TICK_SPACING;
    /// @notice Lowest usable tick at that spacing.
    int24 public constant MIN_TICK = -887_200;
    /// @notice Highest usable tick at that spacing.
    int24 public constant MAX_TICK = 887_200;
    /// @notice Total supply of each launch token, in wei.
    uint256 public constant SUPPLY = BOXA_SUPPLY;
    /// @notice Where rounding dust goes.
    address public constant DEAD = BOXA_DEAD;

    /// @notice What a creator asks for.
    /// @param name Token name.
    /// @param symbol Token symbol.
    /// @param salt Part of the token address's salt, with the creator's address.
    /// @param quote address(0) = native HYPE; otherwise an ERC-20 the hook allows.
    /// @param creatorBps Creator's share of the extra tax after the treasury's cut.
    /// @param buybackBps Buyback's share of it.
    /// @param holdersBps Holders' share of it; the three add up to 10_000.
    /// @param antiSnipe Caps buys in the first minute, and this launch's first buy.
    /// @param buyExtraPips Extra tax on buys on top of the 1% base: 0 to 90_000 (9%), fixed for life.
    /// @param sellExtraPips Extra tax on sells, likewise.
    /// @param expectedExtraCutBps The treasury's cut this launch expects to fix for life.
    /// @param expectedStartTick The opening tick it expects (the hook's for this quote asset).
    /// @param quoteIn First buy, in the quote asset (for HYPE it must equal msg.value).
    /// @param minTokensOut Least the first buy may return.
    /// @param deadline Last timestamp this launch may execute.
    /// @param metadata Free-form, emitted only.
    struct LaunchParams {
        string name;
        string symbol;
        bytes32 salt;
        address quote;
        uint16 creatorBps;
        uint16 buybackBps;
        uint16 holdersBps;
        bool antiSnipe;
        uint24 buyExtraPips;
        uint24 sellExtraPips;
        uint16 expectedExtraCutBps;
        int24 expectedStartTick;
        uint256 quoteIn;
        uint256 minTokensOut;
        uint256 deadline;
        string metadata;
    }

    /// @notice The PoolManager launches happen on.
    IPoolManager public immutable poolManager;
    /// @notice The hook of every pool launched here.
    BoxaUniHookV2 public immutable hook;

    /// @notice A token was launched.
    /// @param token The token.
    /// @param poolId Its pool.
    /// @param creator Who launched it.
    /// @param name Its name.
    /// @param symbol Its symbol.
    /// @param tokensInLiquidity Tokens placed in the locked position.
    /// @param firstBuyTokens Tokens the first buy returned.
    /// @param firstBuyQuote The first buy, in the pool's quote asset.
    /// @param creatorBps Creator's share of the extra tax after the treasury's cut.
    /// @param buybackBps Buyback's share of it.
    /// @param holdersBps Holders' share of it.
    /// @param antiSnipe Whether anti-snipe is on.
    /// @param metadata The creator's free-form metadata.
    event Launched(address indexed token, PoolId indexed poolId, address indexed creator, string name, string symbol,
        uint256 tokensInLiquidity, uint256 firstBuyTokens, uint256 firstBuyQuote, uint16 creatorBps, uint16 buybackBps,
        uint16 holdersBps, bool antiSnipe, string metadata);

    /// @notice The deadline has passed.
    error Expired();
    /// @notice The callback's caller is not the PoolManager.
    error NotPoolManager();
    /// @notice The first buy returned less than `minTokensOut`.
    error InsufficientOutput();
    /// @notice A launch was re-entered.
    error Reentrant();
    /// @notice msg.value does not match the first buy.
    error InvalidValue();
    /// @notice The quote asset delivered or kept a different amount than was sent.
    error QuoteTransferMismatch();
    /// @notice The hook's treasury cut or opening tick differ from what the creator expected.
    error TermsChanged();
    /// @notice An anti-snipe launch's first buy is over the cap.
    error FirstBuyTooLarge();
    /// @notice The first buy is larger than the whole launch curve.
    error FirstBuyExceedsCurve();

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

    /// @param poolManager_ The PoolManager launches happen on.
    /// @param hook_ The hook of every pool launched here.
    constructor(IPoolManager poolManager_, BoxaUniHookV2 hook_) {
        poolManager = poolManager_;
        hook = hook_;
    }

    /// @notice Launches a token, as described on this contract.
    /// @param params See LaunchParams.
    /// @return token The new token.
    /// @return poolId Its pool.
    function launch(LaunchParams calldata params) external payable nonReentrant returns (address token, PoolId poolId) {
        if (block.timestamp > params.deadline) revert Expired();
        int24 startTick = hook.startTickOf(params.quote); // reverts unless the quote asset is allowed
        if (startTick != params.expectedStartTick || hook.extraCutBps() != params.expectedExtraCutBps) revert TermsChanged();
        uint256 quoteBefore = 0;
        if (params.quote == address(0)) {
            if (msg.value != params.quoteIn) revert InvalidValue();
        } else {
            if (msg.value != 0) revert InvalidValue();
            quoteBefore = IERC20(params.quote).balanceOf(address(this));
            if (params.quoteIn != 0) {
                IERC20(params.quote).safeTransferFrom(msg.sender, address(this), params.quoteIn);
                // A quote asset that delivers less than was sent (a transfer fee) is refused.
                if (IERC20(params.quote).balanceOf(address(this)) - quoteBefore != params.quoteIn) revert QuoteTransferMismatch();
            }
        }
        token = address(new BoxaV4TokenV2{salt: keccak256(abi.encode(msg.sender, params.salt))}(
            params.name, params.symbol, address(this), address(hook), address(poolManager)));
        PoolKey memory key = poolKey(token, params.quote);
        bool quoteIs0 = Currency.unwrap(key.currency1) == token;
        hook.register(key, token, msg.sender, params.creatorBps, params.buybackBps, params.holdersBps, params.antiSnipe,
            params.buyExtraPips, params.sellExtraPips);
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(quoteIs0 ? startTick : -startTick));
        (uint256 inLiquidity, uint256 bought) = abi.decode(
            poolManager.unlock(abi.encode(key, quoteIs0, startTick, msg.sender, params.quoteIn)), (uint256, uint256));
        if (bought < params.minTokensOut) revert InsufficientOutput();
        if (params.antiSnipe && bought > hook.MAX_SNIPE_BUY()) revert FirstBuyTooLarge();
        // Rounding leaves a few wei of tokens; they are burned rather than kept.
        uint256 rest = BoxaV4TokenV2(token).balanceOf(address(this));
        if (rest != 0) IERC20(token).safeTransfer(DEAD, rest);
        // Every quote unit taken in went into the pool: nothing stays here.
        if (params.quote != address(0) && IERC20(params.quote).balanceOf(address(this)) != quoteBefore) {
            revert QuoteTransferMismatch();
        }
        poolId = key.toId();
        emit Launched(token, poolId, msg.sender, params.name, params.symbol, inLiquidity, bought, params.quoteIn,
            params.creatorBps, params.buybackBps, params.holdersBps, params.antiSnipe, params.metadata);
    }

    /// @notice Runs inside the PoolManager's unlock: adds the liquidity and makes the first buy.
    /// @param data The launch's arguments, from `launch`.
    /// @return Tokens placed in liquidity and tokens the first buy returned.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, bool quoteIs0, int24 startTick, address creator, uint256 quoteIn) =
            abi.decode(data, (PoolKey, bool, int24, address, uint256));
        Currency tokenC = quoteIs0 ? key.currency1 : key.currency0;
        Currency quoteC = quoteIs0 ? key.currency0 : key.currency1;
        ModifyLiquidityParams memory lp;
        if (quoteIs0) {
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(MIN_TICK), TickMath.getSqrtPriceAtTick(startTick), SUPPLY);
            lp = ModifyLiquidityParams({tickLower: MIN_TICK, tickUpper: startTick, liquidityDelta: int256(uint256(liquidity)), salt: 0});
        } else {
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(-startTick), TickMath.getSqrtPriceAtTick(MAX_TICK), SUPPLY);
            lp = ModifyLiquidityParams({tickLower: -startTick, tickUpper: MAX_TICK, liquidityDelta: int256(uint256(liquidity)), salt: 0});
        }
        (BalanceDelta added,) = poolManager.modifyLiquidity(key, lp, "");
        uint256 owed = uint256(int256(-(quoteIs0 ? added.amount1() : added.amount0())));
        poolManager.sync(tokenC);
        IERC20(Currency.unwrap(tokenC)).safeTransfer(address(poolManager), owed);
        poolManager.settle();
        uint256 bought = 0;
        if (quoteIn != 0) {
            BalanceDelta swapped = poolManager.swap(key, SwapParams({zeroForOne: quoteIs0, amountSpecified: -int256(quoteIn),
                sqrtPriceLimitX96: quoteIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}), "");
            uint256 paid = uint256(int256(-(quoteIs0 ? swapped.amount0() : swapped.amount1())));
            bought = uint256(int256(quoteIs0 ? swapped.amount1() : swapped.amount0()));
            // The hook already refuses a partial fill; this keeps the launcher right on its own.
            if (paid != quoteIn) revert FirstBuyExceedsCurve();
            poolManager.sync(quoteC);
            if (quoteC.isAddressZero()) {
                poolManager.settle{value: paid}();
            } else {
                IERC20(Currency.unwrap(quoteC)).safeTransfer(address(poolManager), paid);
                poolManager.settle();
            }
            poolManager.take(tokenC, creator, bought);
        }
        return abi.encode(owed, bought);
    }

    /// @notice The pool key for a BOXA token paired with `quote`.
    /// @param token The token.
    /// @param quote address(0) = native HYPE, or an ERC-20.
    /// @return The key.
    function poolKey(address token, address quote) public view returns (PoolKey memory) {
        (address c0, address c1) = quote < token ? (quote, token) : (token, quote);
        return PoolKey({currency0: Currency.wrap(c0), currency1: Currency.wrap(c1), fee: 0, tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))});
    }

    /// @notice The token address a creator gets for a given name, symbol and salt.
    /// @param creator The creator.
    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    /// @param salt The launch's salt.
    /// @return The address.
    function predictToken(address creator, string calldata name_, string calldata symbol_, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes32 initHash = keccak256(abi.encodePacked(type(BoxaV4TokenV2).creationCode,
            abi.encode(name_, symbol_, address(this), address(hook), address(poolManager))));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this),
            keccak256(abi.encode(creator, salt)), initHash)))));
    }
}
