---
"@40-acres/contracts": patch
---

YieldBasis: `YieldBasisLpClaimingFacet` and `DynamicYieldBasisLpClaimingFacet` views (`getDepositInfo`, `getAvailableLpFeeYield`) now return value fields (`depositedUnderlyingValue`, `currentUnderlyingValue`, `yieldUnderlying`) in the underlying token's native decimals, matching the ERC4626 collateral views. Previously these were 18-decimal normalized. Share-count fields (`shares`, `yieldGaugeShares`) and ABI signatures are unchanged; behavior differs only for non-18-decimal underlyings.
