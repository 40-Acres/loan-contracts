---
"@40-acres/contracts": patch
---

DynamicFeesVault: route the cap-the-pull excess in `depositRewards` to the portfolio owner (via `_transferOrEscrow`, including the fully-settled `retain == 0` case) instead of stranding it in the portfolio account. ABI unchanged.
