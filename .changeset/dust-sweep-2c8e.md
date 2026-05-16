---
"@40-acres/contracts": patch
---

DynamicFeesVault: at the epoch boundary inside `_processGlobalVesting`, consume any residual `totalUnsettledRewards` (floor-division dust from `depositRewards`) into the same lender-premium / borrower-credit split as the rest of the vested amount. Previously dust accumulated indefinitely and was permanently subtracted from `totalAssets()`, slightly understating NAV and inflating measured utilization. ABI unchanged.
