---
"@40-acres/contracts": patch
---

ERC4626LendingFacet: fix `pay()` return-value contract. Previously returned only post-pull excess after capping `amount` to current debt, silently dropping the pre-cap portion. `RewardsProcessingFacet._payDebtToTarget` derives `amountPaid = amountToPay - excess`, so an overpayment to a low-debt target was overstated and remaining funds idled in the source portfolio. Now returns `requestedAmount - actuallyPaid`, matching `BaseLendingFacet`. Also adds NatSpec to `ILendingFacet.pay` locking the return-value contract. ABI unchanged.
