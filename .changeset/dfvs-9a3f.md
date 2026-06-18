---
"@40-acres/contracts": patch
---

DynamicFeesVault: dedup reward-stream vesting math into a shared internal `_computeVestStep` helper. `_processGlobalVesting` now persists the result of `_simulateVesting` (single source of truth) instead of recomputing it, and `_simulateBorrowerCreditPerRateAt` reuses the same helper. Behavior-preserving refactor; no ABI change.
