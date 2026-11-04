// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

/// @notice How a BOXA launch fee is divided, in whatever currency the pool's quote asset is (native
///         HYPE or an allowlisted ERC-20). Pure integer math, shared by the hook and its previews.
/// - Fee = base + extra, rounded UP as a whole (the trader never pays less than the rate):
///   fee  = ceil(amount * (1% + extraPips) / 1e6), base = ceil(amount * 1% / 1e6), extra = fee - base.
///   Since base <= fee <= amount, the fee never exceeds the amount it is taken from.
/// - Base: BASE_TREASURY_BPS (30%) to BOXA's treasury, rounded down; the creator gets the rest.
/// - Extra: `extraCutBps` of it to the treasury (rounded down); of what is left, creatorBps to the
///   creator and holdersBps to holders (each rounded down) and buyback takes the remainder.
/// fee = treasury + creator + buyback + holders, exactly; nothing is lost.
library BoxaFeeSplit {
    uint256 internal constant PIPS = 1_000_000;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant BASE_FEE_PIPS = 10_000;     // 1%
    uint256 internal constant BASE_TREASURY_BPS = 3_000;  // 30% of the base fee

    struct Split {
        uint256 fee;       // base + extra
        uint256 base;      // the 1% part
        uint256 extra;     // the creator's extra tax part
        uint256 treasury;  // 30% of base + extraCutBps of extra
        uint256 creator;   // 70% of base (with its remainder) + creatorBps of the extra after the cut
        uint256 buyback;   // buybackBps of the extra after the cut, with that split's remainder
        uint256 holders;   // holdersBps of the extra after the cut
    }

    function split(uint256 amount, uint256 extraPips, uint256 extraCutBps, uint256 creatorBps, uint256 holdersBps)
        internal
        pure
        returns (Split memory s)
    {
        s.fee = _ceilDiv(amount * (BASE_FEE_PIPS + extraPips), PIPS);
        s.base = _ceilDiv(amount * BASE_FEE_PIPS, PIPS);
        s.extra = s.fee - s.base;
        uint256 baseTreasury = s.base * BASE_TREASURY_BPS / BPS;
        uint256 extraTreasury = s.extra * extraCutBps / BPS;
        uint256 net = s.extra - extraTreasury;
        uint256 extraCreator = net * creatorBps / BPS;
        s.holders = net * holdersBps / BPS;
        s.buyback = net - extraCreator - s.holders;
        s.treasury = baseTreasury + extraTreasury;
        s.creator = s.base - baseTreasury + extraCreator;
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
