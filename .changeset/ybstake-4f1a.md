---
"@40-acres/contracts": patch
---

YieldBasis: `YieldBasisLpFacet.setStakedMode()` and `DynamicYieldBasisLpFacet.setStakedMode()` now enforce collateral neutrality when sweeping into the gauge. The stake branch snapshots the shortfall baseline before staking, rejects a lossy sweep outright (`require(gauge.convertToAssets(sharesMinted) >= lpSent, "Lossy stake")`), then reconciles tracked shares to actual recoverable LP and re-checks collateral (guarding pre-existing gauge drift). Previously the stake branch deposited LP with no reconciliation, so a gauge minting fewer recoverable shares than LP sent could silently under-secure an at-limit position. The `deposit()` auto-stake path is intentionally left unguarded so adding collateral to an already-drifted gauge stays deadlock-free. Solidity-only fix, ABI unchanged.
