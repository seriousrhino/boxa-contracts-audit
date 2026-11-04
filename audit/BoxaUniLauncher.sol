// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {BoxaV4Token} from "./BoxaV4Token.sol";
import {BoxaUniHook} from "./BoxaUniHook.sol";

/// @notice Launches a BOXA token in one transaction on BoxaUniHook's PoolManager: creates the token,
///         registers and initializes its pool against the chosen quote asset (native HYPE or an
///         allowlisted ERC-20), places the whole supply as single-sided liquidity that can never be
///         removed, and optionally makes the creator's first buy. Keeps no funds, has no owner and
///         no function to touch the liquidity. Based on BoxaV4Launcher.
/// The opening price is the hook's start tick for the quote asset, in tokens per quote unit. When the
/// quote asset sorts first (always for HYPE) the token is currency1 and its liquidity sits from MIN_TICK
/// up to that tick; otherwise the token is currency0 and its liquidity sits from the inverted tick up
/// to MAX_TICK. Either way the pool opens at the edge of the position, holding only the token.
contract BoxaUniLauncher is IUnlockCallback {
    using SafeTransferLib for ERC20;

    int24 public constant TICK_SPACING = 200;
    int24 public constant MIN_TICK = -887_200;
    int24 public constant MAX_TICK = 887_200;
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct LaunchParams {
        string name;
        string symbol;
        bytes32 salt;
        address quote;        // address(0) = native HYPE; otherwise an ERC-20 the hook allows
        uint16 creatorBps;
        uint16 buybackBps;
        uint16 holdersBps;    // creatorBps + buybackBps + holdersBps = 10_000
        bool antiSnipe;
        uint24 buyExtraPips;  // extra tax on top of the 1% base: 0 to 90_000 (9%), fixed for the token's life
        uint24 sellExtraPips;
        uint256 quoteIn;      // first buy, in the quote asset (for HYPE it must equal msg.value)
        uint256 minTokensOut;
        uint256 deadline;
        string metadata;
    }

    IPoolManager public immutable poolManager;
    BoxaUniHook public immutable hook;

    uint256 private entered = 1;

    /// @dev Same shape as BoxaV4Launcher's; firstBuyHype is the first buy in the pool's quote asset.
    event Launched(address indexed token, PoolId indexed poolId, address indexed creator, string name, string symbol,
        uint256 tokensInLiquidity, uint256 firstBuyTokens, uint256 firstBuyHype, uint16 creatorBps, uint16 buybackBps,
        uint16 holdersBps, bool antiSnipe, string metadata);

    error Expired();
    error NotPoolManager();
    error InsufficientOutput();
    error Reentrant();
    error InvalidValue();
    error QuoteTransferMismatch();

    constructor(IPoolManager poolManager_, BoxaUniHook hook_) {
        poolManager = poolManager_;
        hook = hook_;
    }

    function launch(LaunchParams calldata params) external payable returns (address token, PoolId poolId) {
        if (entered != 1) revert Reentrant();
        entered = 2;
        if (block.timestamp > params.deadline) revert Expired();
        int24 startTick = hook.startTickOf(params.quote); // reverts unless the quote asset is allowed
        uint256 quoteBefore;
        if (params.quote == address(0)) {
            if (msg.value != params.quoteIn) revert InvalidValue();
        } else {
            if (msg.value != 0) revert InvalidValue();
            quoteBefore = ERC20(params.quote).balanceOf(address(this));
            if (params.quoteIn != 0) {
                ERC20(params.quote).safeTransferFrom(msg.sender, address(this), params.quoteIn);
                // A quote asset that delivers less than was sent (a transfer fee) is refused.
                if (ERC20(params.quote).balanceOf(address(this)) - quoteBefore != params.quoteIn) revert QuoteTransferMismatch();
            }
        }
        token = address(new BoxaV4Token{salt: keccak256(abi.encode(msg.sender, params.salt))}(
            params.name, params.symbol, address(this), address(hook), address(poolManager)));
        PoolKey memory key = poolKey(token, params.quote);
        bool quoteIs0 = Currency.unwrap(key.currency1) == token;
        hook.register(key, token, msg.sender, params.creatorBps, params.buybackBps, params.holdersBps, params.antiSnipe,
            params.buyExtraPips, params.sellExtraPips);
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(quoteIs0 ? startTick : -startTick));
        (uint256 inLiquidity, uint256 bought) = abi.decode(
            poolManager.unlock(abi.encode(key, quoteIs0, startTick, msg.sender, params.quoteIn)), (uint256, uint256));
        if (bought < params.minTokensOut) revert InsufficientOutput();
        // Rounding leaves a few wei of tokens; they are burned rather than kept.
        uint256 rest = BoxaV4Token(token).balanceOf(address(this));
        if (rest != 0) BoxaV4Token(token).transfer(DEAD, rest);
        // Every quote unit taken in went into the pool: nothing stays here.
        if (params.quote != address(0) && ERC20(params.quote).balanceOf(address(this)) != quoteBefore) {
            revert QuoteTransferMismatch();
        }
        poolId = key.toId();
        emit Launched(token, poolId, msg.sender, params.name, params.symbol, inLiquidity, bought, params.quoteIn,
            params.creatorBps, params.buybackBps, params.holdersBps, params.antiSnipe, params.metadata);
        entered = 1;
    }

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
        BoxaV4Token(Currency.unwrap(tokenC)).transfer(address(poolManager), owed);
        poolManager.settle();
        uint256 bought;
        if (quoteIn != 0) {
            BalanceDelta swapped = poolManager.swap(key, SwapParams({zeroForOne: quoteIs0, amountSpecified: -int256(quoteIn),
                sqrtPriceLimitX96: quoteIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1}), "");
            uint256 paid = uint256(int256(-(quoteIs0 ? swapped.amount0() : swapped.amount1())));
            bought = uint256(int256(quoteIs0 ? swapped.amount1() : swapped.amount0()));
            // A first buy larger than the whole curve cannot be filled; refuse it rather than keep anything.
            if (paid != quoteIn) revert InsufficientOutput();
            poolManager.sync(quoteC);
            if (quoteC.isAddressZero()) {
                poolManager.settle{value: paid}();
            } else {
                ERC20(Currency.unwrap(quoteC)).safeTransfer(address(poolManager), paid);
                poolManager.settle();
            }
            poolManager.take(tokenC, creator, bought);
        }
        return abi.encode(owed, bought);
    }

    /// @notice The pool key for a BOXA token paired with `quote` (address(0) = native HYPE).
    function poolKey(address token, address quote) public view returns (PoolKey memory) {
        (address c0, address c1) = quote < token ? (quote, token) : (token, quote);
        return PoolKey({currency0: Currency.wrap(c0), currency1: Currency.wrap(c1), fee: 0, tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))});
    }

    /// @notice The token address a creator gets for a given name, symbol and salt.
    function predictToken(address creator, string calldata name_, string calldata symbol_, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes32 initHash = keccak256(abi.encodePacked(type(BoxaV4Token).creationCode,
            abi.encode(name_, symbol_, address(this), address(hook), address(poolManager))));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this),
            keccak256(abi.encode(creator, salt)), initHash)))));
    }
}
