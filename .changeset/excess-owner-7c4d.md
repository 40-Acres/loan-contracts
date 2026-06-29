---
"@40-acres/contracts": patch
---

DynamicFeesVault: route excess borrower rewards (after debt is fully repaid) to the portfolio owner instead of the portfolio account. Both the direct-transfer and escrow-on-failure paths now resolve the owner via `PortfolioFactory.ownerOf`, so escrowed excess is claimable by the owner. ABI unchanged.
