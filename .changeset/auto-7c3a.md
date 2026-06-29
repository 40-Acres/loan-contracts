---
"@40-acres/contracts": patch
---

YieldBasis: fix LP-fee harvest principal leak. `removeSharesForYield` in `YieldBasisCollateralManager` and `DynamicYieldBasisCollateralManager` now holds `depositedAssetValue` fixed and re-checks "Would remove principal" against the remaining LP basis, instead of shrinking the basis pro-rata. Re-harvesting at an unchanged `pricePerShare` no longer walks principal out of collateral as fake yield. No ABI change.
