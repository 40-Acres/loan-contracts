---
"@40-acres/contracts": minor
---

DynamicFeesVault: add `activeAssetsConservative()` (outstanding loaned assets crediting only reward credit already applied to debt, excluding unsettled `globalBorrowerPending`) and a new `IDynamicLendingPool` interface exposing it. The Dynamic collateral managers (`DynamicCollateralManager`, `DynamicYieldBasisCollateralManager`, `DynamicHydrexCollateralManager`) now read the conservative value as `outstandingCapital` for borrow-cap gating, so a borrow can no longer exceed the true utilization cap during the pre-settlement window (the prior `activeAssets()` read under-stated outstanding by the unsettled borrower credit, inflating headroom). `activeAssets()` is unchanged. New ABI surface (getter + interface).
