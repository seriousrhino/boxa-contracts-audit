# BOXA V2 launch contracts for re-audit

Source commit 49b7c35 (branch audit-fixes). Not deployed. Findings and responses: AUDIT-RESPONSE.md.

| Contract | Role |
|---|---|
| contracts/BoxaUniHookV2.sol | Uniswap v4 hook serving every launch pool: fees, holder rewards, buyback, anti-snipe |
| contracts/BoxaUniLauncherV2.sol | Creates a token, its pool and locked liquidity in one transaction |
| contracts/BoxaV4TokenV2.sol | Fixed-supply launch token with holder reward bookkeeping |
| contracts/BoxaFeeSplitV2.sol | Library dividing a fee |
| contracts/BoxaUniConstants.sol | Constants shared by the above |

Build settings and dependency commits are at the end of AUDIT-RESPONSE.md. Tests are in the repository under v4/test
(BoxaUniV2.t.sol, BoxaUniV2Invariant.t.sol, BoxaUniV2Gas.t.sol).
