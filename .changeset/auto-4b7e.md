---
"@40-acres/contracts": patch
---

DynamicFeesVault: `maxWithdraw`/`maxRedeem` now cap lender exits at free liquidity (NAV minus outstanding debt) instead of the raw asset balance. Previously a lender could withdraw into funds earmarked as liabilities -- unvested lender premium, unsettled rewards, aggregate excess owed to borrowers, and escrowed excess -- potentially leaving the vault unable to satisfy what it owes others. The cap now reserves exactly what `totalAssets()` already deducts. Internal-only change; `maxWithdraw`/`maxRedeem` signatures and the exported ABI are unchanged (returned values are tighter).
