---
"@40-acres/contracts": minor
---

DynamicFeesVault: `depositRewards` now caps the pulled reward amount to the worst-case stream needed to cover the borrower's own debt (`retain = ceilDiv(debt * 10000, 10000 - getVaultRatioBps(10000))`). Reward USDC beyond that is left in the depositor's wallet instead of being streamed and later refunded as excess. New `RewardsDepositCapped(borrower, requested, retained)` event for downstream indexers. Behavior change: lenders earn premium only on the retained portion, so a borrower over-depositing far above their debt no longer routes the excess (and its lender-premium cut) through the vault. ABI is additive (new event only); `depositRewards` signature unchanged. The matching settled `activeAssets()` borrow-cap read ships in the same PR.
