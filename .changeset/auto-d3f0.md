---
"@40-acres/contracts": minor
---

All platforms: add `FortyAcresDepositor` (`src/accounts/FortyAcresDepositor.sol`, ABI exported) -- a standalone, ownerless push contract that is the single fixed spender users approve for deposits, replacing approvals to the (not yet deployed) per-user portfolio account. `deposit721` / `deposit20` move the caller's own asset into the caller's own portfolio at a factory registered with the managers fixed at construction, creating the account first if needed. No core contract changes. No addresses yet: deploy per chain with `DeployFortyAcresDepositor.s.sol` and register the `depositor` key in `addresses/`.
