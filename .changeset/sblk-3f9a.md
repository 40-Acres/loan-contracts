---
"@40-acres/contracts": patch
---

DynamicFeesVault + LendingVault: close the same-block flash-deposit guard bypass. The guard previously pinned a holder only when `caller == receiver`, so a third-party `deposit`/`mint` to an address left it unpinned and able to round-trip out the same block. The guard now pins shares acquired this block (mint or transfer-in) via an `_update` override and gates withdraw/redeem on `balanceOf(owner) >= shares + sameBlockAcquired`, so only freshly-acquired shares are locked while pre-existing balance stays withdrawable (griefing-resistant). No external ABI change.
