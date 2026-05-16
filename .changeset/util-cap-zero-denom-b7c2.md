---
"@40-acres/contracts": patch
---

LendingVault & DynamicFeesVault: revert `borrowFromPortfolio` when `totalAssets() == 0` and tighten the utilization cap to a strict-inequality multiplication form. Previously a zero-supply vault treated utilization as 0% and allowed borrows past the cap. No ABI change.
