---
"@40-acres/contracts": patch
---

ERC4626 and YieldBasis collateral managers: `decreaseTotalDebt` (repay) no longer reverts when the collateral source reverts during a pause/emergency. The repay-path shortfall snapshot now wraps the external collateral read (ERC4626 `previewRedeem`; YieldBasis `pricePerShare`/`preview_withdraw` and gauge `convertToAssets`) in try/catch and skips the snapshot on failure, so borrowers can always reduce debt. Borrow-side reads are unchanged and still revert on paused collateral. ABI unchanged.
