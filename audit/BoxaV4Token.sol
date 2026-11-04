// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Fixed-supply launch token for BOXA v4. The whole supply is minted once to the
///         launcher, which places it in the locked pool. No owner, no mint, no transfer rules.
/// @dev It also keeps the books for holder rewards: the hook adds HYPE with `distribute`, and
///      every holder earns it in proportion to the tokens they hold at that moment. The pool
///      (PoolManager), the launcher, the hook and the burn address never earn, so rewards go only
///      to real holders. The HYPE itself stays with the hook, which pays a holder's claim after
///      `withdraw` records it here. Standard reward-per-share accounting with per-account corrections.
contract BoxaV4Token is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    /// @dev Below one whole token held by earners, rewards are not split (the hook sends them to
    ///      buyback instead); this also bounds the reward-per-share value against overflow.
    uint256 public constant MIN_EARNING_SUPPLY = 1 ether;
    uint256 private constant MAGNITUDE = 2 ** 128;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable hook;
    address public immutable poolManager;
    address public immutable launcher;

    /// @notice Tokens held by accounts that earn rewards.
    uint256 public earningSupply;
    uint256 private rewardPerShare; // HYPE wei per token wei, times MAGNITUDE
    mapping(address => int256) private corrections;
    /// @notice HYPE each holder has already claimed.
    mapping(address => uint256) public withdrawn;

    error NotHook();

    constructor(string memory name_, string memory symbol_, address launcher_, address hook_, address poolManager_)
        ERC20(name_, symbol_, 18)
    {
        launcher = launcher_;
        hook = hook_;
        poolManager = poolManager_;
        _mint(launcher_, INITIAL_SUPPLY);
    }

    /// @notice Whether `account` earns holder rewards.
    function earns(address account) public view returns (bool) {
        return account != poolManager && account != launcher && account != hook && account != DEAD && account != address(0);
    }

    /// @notice HYPE `account` has earned and not yet claimed.
    function rewardsOf(address account) public view returns (uint256) {
        if (!earns(account)) return 0;
        uint256 total = uint256(int256(rewardPerShare * balanceOf[account]) + corrections[account]) / MAGNITUDE;
        return total - withdrawn[account];
    }

    /// @notice Shares `amount` HYPE among current holders. Returns false, recording nothing, when
    ///         too few tokens are held for a fair split.
    function distribute(uint256 amount) external returns (bool) {
        if (msg.sender != hook) revert NotHook();
        if (earningSupply < MIN_EARNING_SUPPLY) return false;
        rewardPerShare += amount * MAGNITUDE / earningSupply;
        return true;
    }

    /// @notice Records a holder's claim of everything earned; the hook pays it.
    function withdraw(address account) external returns (uint256 amount) {
        if (msg.sender != hook) revert NotHook();
        amount = rewardsOf(account);
        withdrawn[account] += amount;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _track(msg.sender, to, amount);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _track(from, to, amount);
        return super.transferFrom(from, to, amount);
    }

    /// @dev Moving tokens moves future earnings, never past ones.
    function _track(address from, address to, uint256 amount) private {
        if (from == to) return;
        int256 shift = int256(rewardPerShare * amount);
        bool fromEarns = earns(from);
        bool toEarns = earns(to);
        if (fromEarns) { corrections[from] += shift; earningSupply -= amount; }
        if (toEarns) { corrections[to] -= shift; earningSupply += amount; }
    }
}
