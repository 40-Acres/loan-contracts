---
"@40-acres/contracts": major
---

Remove unused `getTotalDebt()` and `getMaxLoan()` from the ERC4626 and YieldBasis lending facets (`ERC4626LendingFacet`, `DynamicERC4626LendingFacet`, `YieldBasisLpLendingFacet`, `DynamicYieldBasisLpLendingFacet`). These selectors are registered on the diamond only through the matching collateral facets, so the lending-facet copies were dead code. The exported `ERC4626LendingFacet` ABI loses both functions (breaking for consumers typing against that ABI), hence major. Both selectors remain live on the diamond, served by the collateral facets, so on-chain calls are unaffected -- consumers should read `getTotalDebt`/`getMaxLoan` via the `ERC4626CollateralFacet` ABI instead.
