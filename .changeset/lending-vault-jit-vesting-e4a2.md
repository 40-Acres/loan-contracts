---
"@40-acres/contracts": patch
---

LendingVault: fix JIT sandwich on mid-epoch `depositRewards`. Mid-epoch deposits now contribute `amount * WEEK / remaining` to `currentEpochRewards`, so `totalAssets()` stays invariant at the moment of deposit and the reward vests linearly from now until epoch end. Appended `currentEpochActualRewards` storage slot; `lastEpochReward()` reads from it for a truthful per-epoch token count. ABI unchanged.
