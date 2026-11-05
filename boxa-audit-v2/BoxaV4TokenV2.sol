// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {BOXA_DEAD, BOXA_SUPPLY} from "./BoxaUniConstants.sol";

/// @title BOXA launch token, version 2
/// @notice Fixed-supply launch token. The whole supply is minted once to the launcher, which places it
///         in the locked pool. No owner, no mint, no transfer rules.
/// @dev It also keeps the books for holder rewards: the hook adds the pool's quote asset with
///      `distribute`, and every holder earns it in proportion to the tokens they hold at that moment.
///      The pool (PoolManager), the launcher, the hook and the burn address never earn. The quote asset
///      itself stays with the hook, which pays a holder's claim after `withdraw` records it here.
///      Standard reward-per-share accounting with per-account corrections.
///
///      Differs from BoxaV4Token:
///      - A transaction in which an earner's balance moved cannot share out rewards: `distribute`
///        answers Deferred and the hook keeps the amount pending. So a share-out in any transaction
///        sees the balances as they stood when that transaction began, and tokens held only within a
///        transaction earn nothing, wherever they were borrowed or bought. The flag lives in transient
///        storage and clears when the transaction ends: it costs 100 gas per transfer, needs no
///        per-account storage, and nobody can use it to hold up another transaction's share-out.
///      - The reward per share is capped so that its product with any balance always fits an int256;
///        past the cap `distribute` answers NotShared and the hook sends the amount to buyback.
///      - Events for share-outs and withdrawals, getters for the reward state, zero-address checks.
contract BoxaV4TokenV2 is ERC20 {
    /// @notice The answer to a share-out: Shared; NotShared, for good (too few tokens are held, or the
    ///         reward per share would pass its cap); or Deferred, try again in another transaction.
    enum Distribution { Shared, NotShared, Deferred }

    /// @notice Total supply, in wei.
    uint256 public constant INITIAL_SUPPLY = BOXA_SUPPLY;
    /// @notice Below one whole token held by earners, rewards are not split.
    uint256 public constant MIN_EARNING_SUPPLY = 1 ether;
    /// @notice The highest reward per share: times the whole supply it still fits an int256.
    uint256 public constant MAX_REWARD_PER_SHARE = uint256(type(int256).max) / BOXA_SUPPLY;
    uint256 private constant MAGNITUDE = 2 ** 128;

    /// @notice The hook that alone may share out rewards and record withdrawals.
    address public immutable hook;
    /// @notice The PoolManager holding the pool's tokens; it does not earn.
    address public immutable poolManager;
    /// @notice The launcher that received the supply; it does not earn.
    address public immutable launcher;

    /// @notice Tokens held by accounts that earn rewards.
    uint256 public earningSupply;
    /// @notice Quote asset wei earned per token wei since launch, times 2^128.
    uint256 public rewardPerShare;
    mapping(address => int256) private corrections;
    /// @notice Quote asset each holder has already claimed.
    mapping(address => uint256) public withdrawn;

    /// @notice `amount` of the quote asset was shared among holders.
    /// @param amount Amount shared.
    /// @param rewardPerShare The reward per share afterwards.
    event Distributed(uint256 amount, uint256 rewardPerShare);
    /// @notice A holder's claim was recorded; the hook pays it.
    /// @param account The holder.
    /// @param amount Amount recorded.
    event Withdrawn(address indexed account, uint256 amount);

    /// @notice The caller is not the hook.
    error NotHook();
    /// @notice A constructor address was zero.
    error ZeroAddress();

    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    /// @param launcher_ Receives the whole supply.
    /// @param hook_ The hook of this token's pool.
    /// @param poolManager_ The PoolManager of this token's pool.
    constructor(string memory name_, string memory symbol_, address launcher_, address hook_, address poolManager_)
        ERC20(name_, symbol_, 18)
    {
        if (launcher_ == address(0) || hook_ == address(0) || poolManager_ == address(0)) revert ZeroAddress();
        launcher = launcher_;
        hook = hook_;
        poolManager = poolManager_;
        _mint(launcher_, INITIAL_SUPPLY);
    }

    /// @notice Whether `account` earns holder rewards.
    /// @param account The account.
    /// @return True unless it is the PoolManager, launcher, hook, burn address or zero.
    function earns(address account) public view returns (bool) {
        return account != poolManager && account != launcher && account != hook && account != BOXA_DEAD && account != address(0);
    }

    /// @notice What `account` has earned and not yet claimed.
    /// @param account The account.
    /// @return The amount, in the pool's quote asset.
    function rewardsOf(address account) public view returns (uint256) {
        if (!earns(account)) return 0;
        uint256 total = uint256(int256(rewardPerShare * balanceOf[account]) + corrections[account]) / MAGNITUDE;
        return total - withdrawn[account];
    }

    /// @notice The bookkeeping correction of `account`, for anyone reconstructing its rewards.
    /// @param account The account.
    /// @return The correction: moved balance times the reward per share at the time.
    function correctionOf(address account) external view returns (int256) {
        return corrections[account];
    }

    /// @notice Whether an earner's balance has moved in the current transaction.
    /// @return moved True if it has; rewards cannot be shared out until a later transaction.
    function movedThisTransaction() public view returns (bool moved) {
        assembly ("memory-safe") {
            moved := tload(0)
        }
    }

    /// @notice Shares `amount` among current holders.
    /// @param amount Amount of the quote asset to share.
    /// @return What happened; only Shared records anything.
    function distribute(uint256 amount) external returns (Distribution) {
        if (msg.sender != hook) revert NotHook();
        if (movedThisTransaction()) return Distribution.Deferred;
        if (earningSupply < MIN_EARNING_SUPPLY || amount > type(uint128).max) return Distribution.NotShared;
        uint256 next = rewardPerShare + amount * MAGNITUDE / earningSupply;
        if (next > MAX_REWARD_PER_SHARE) return Distribution.NotShared;
        rewardPerShare = next;
        emit Distributed(amount, next);
        return Distribution.Shared;
    }

    /// @notice Records a holder's claim of everything earned; the hook pays it.
    /// @param account The holder.
    /// @return amount The amount recorded.
    function withdraw(address account) external returns (uint256 amount) {
        if (msg.sender != hook) revert NotHook();
        amount = rewardsOf(account);
        withdrawn[account] += amount;
        emit Withdrawn(account, amount);
    }

    /// @inheritdoc ERC20
    function transfer(address to, uint256 amount) public override returns (bool) {
        _track(msg.sender, to, amount);
        return super.transfer(to, amount);
    }

    /// @inheritdoc ERC20
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _track(from, to, amount);
        return super.transferFrom(from, to, amount);
    }

    /// @dev Moving tokens moves future earnings, never past ones. A move that changes no earner's
    ///      balance (a burn from the pool, the launcher placing liquidity) touches nothing here.
    function _track(address from, address to, uint256 amount) private {
        if (from == to) return;
        bool fromEarns = earns(from);
        bool toEarns = earns(to);
        if (!fromEarns && !toEarns) return;
        assembly ("memory-safe") {
            tstore(0, 1)
        }
        int256 shift = int256(rewardPerShare * amount);
        if (fromEarns) { corrections[from] += shift; earningSupply -= amount; }
        if (toEarns) { corrections[to] -= shift; earningSupply += amount; }
    }
}
