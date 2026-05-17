---
"@40-acres/contracts": minor
---

Portfolio accounts: add configurable treasury address (`setTreasury`/`getTreasury` + `TreasuryUpdated` event) to `LoanConfig`, `LendingVault`, and `DynamicFeesVault`. Protocol fees, origination fees, zero-balance fees, and the claim-flow treasury fee now route to `LoanConfig.getTreasury()` (or the vault's own `getTreasury()` for vault-collected fees) instead of `owner()`. Unset treasury falls back to `owner()`, preserving existing deployment behavior.
