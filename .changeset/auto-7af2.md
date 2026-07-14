---
"@40-acres/contracts": patch
---

DynamicFeesVault: `activeAssets()` now credits only reward credit already applied to debt (`totalVestedRewardsApplied`), excluding unsettled `globalBorrowerPending` whose per-borrower debt reduction is not yet known. Outstanding loaned assets is only ever over-stated, so the Dynamic collateral managers' borrow-cap gating (`outstandingCapital`) can no longer see inflated headroom during the pre-settlement window. Signature and ABI unchanged; returned values are tighter.
