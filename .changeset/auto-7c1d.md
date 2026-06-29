---
"@40-acres/contracts": patch
---

YieldBasis: `_resolveCollateralValue` in `YieldBasisCollateralManager` and `DynamicYieldBasisCollateralManager` now down-scales `preview_withdraw` for underlyings with more than 18 decimals (symmetric to the existing sub-18 up-scale), so the conservative collateral mark normalizes `withdrawable` to 18-dec for any underlying. ABI unchanged.
