---
"@40-acres/contracts": patch
---

DynamicFeesVault: `totalAssets()` now simulates pending reward-stream vesting so ERC4626 preview/max views match the values mint/burn would see after settlement. Closes a stale-NAV gap where mid-epoch depositors could capture the already-vested fraction of lender premium they did not fund.
