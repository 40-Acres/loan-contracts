---
"@40-acres/contracts": patch
---

ERC4626 + YieldBasis collateral managers (ERC4626CollateralManager, YieldBasisCollateralManager, DynamicYieldBasisCollateralManager): `removeCollateral` now reverts `BelowMinimumCollateral` when a partial withdrawal would leave live collateral value in (0, `getMinimumCollateral()`); full exits (remaining value 0) still allowed. No-op when the minimum is unset (0). Reuses the existing single minimum config and applies regardless of debt. ABI unchanged (adds an error only).
