---
"@40-acres/contracts": patch
---

YieldBasis: `getTotalCollateralValue` and `_snapshotIfNeeded` now reconcile `data.shares` against actual recoverable LP (direct balance + gauge `convertToAssets`) before pricing and shortfall computation. Closes a defense-in-depth gap where a gauge drift between deposit and the next admin reconcile could let a borrower draw against phantom shares. Also: `DynamicYieldBasisLpLendingFacet.borrow` gains a `nonReentrant` guard to match `pay`/`topUp`. No ABI changes.
