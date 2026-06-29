---
"@40-acres/contracts": patch
---

YieldBasis: `YieldBasisLpFacet.setStakedMode()` now enforces collateral neutrality on the stake branch. It snapshots the shortfall baseline before staking, then reconciles tracked shares to actual recoverable LP and re-checks collateral after, so a lossy gauge deposit (fewer recoverable shares than LP sent) reverts `UndercollateralizedDebt` instead of silently under-securing an at-limit position. Solidity-only fix, ABI unchanged.
