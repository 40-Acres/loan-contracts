---
"@40-acres/contracts": minor
---

Add 9 facet ABIs to the package:

- `collateralFacetAbi`, `erc4626CollateralFacetAbi` — collateral management
  (addCollateral, removeCollateral, getLockedCollateral, etc.)
- `erc4626LendingFacetAbi` — borrow, getTotalDebt
- `rewardsProcessingFacetAbi` — pay
- `yieldBasisLpFacetAbi` — deposit, withdraw
- `veYieldBasisFacetAbi` — createLock, increaseLock
- `dynamicVotingEscrowFacetAbi` — merge, mergeInternal
- `votingFacetAbi` — batchVote, setVotingMode
- `xPharaohFacetAbi` — Pharaoh's V1 facet (xPhar* methods),
  still actively used in production despite living under `src/legacy/`.

Replaces the frontend's hand-typed `FACETS_ABI` (a synthetic union over
the diamond proxy) with individual facet ABIs that consumers pick per
call site. Also unblocks the migration of `phar_abi.ts` to the package.
