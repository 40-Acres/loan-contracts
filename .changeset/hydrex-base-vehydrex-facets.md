---
"@40-acres/contracts": minor
---

Hydrex (Base): add veHydrex account facets (`VeHydrexFacet`, `VeHydrexClaimingFacet`, `VeHydrexVotingEscrowFacet`) plus their `Dynamic*` variants under `src/facets/account/veHydrex/`. Voting is account-wide (Hydrex's Voter auto-resets), claim entry points cover fees/bribes and rebase, and a per-account rebase-bucket pattern (tracked on `HydrexPortfolioFactoryConfig`) absorbs the fresh PERMANENT veNFT that Hydrex's RewardsDistributor mints for non-PERMANENT originals. ROLLING + PERMANENT lock types only; NON_PERMANENT deposits auto-convert to ROLLING in the receiver hook. Also adds `HydrexCollateralManager` / `DynamicHydrexCollateralManager` (distinct storage slots, `lockDetails`-based reads) plus the supporting `DynamicHydrexCollateralFacet` / `DynamicHydrexLendingFacet` / `DynamicHydrexRewardsProcessingFacet` so a Hydrex diamond can be deployed end to end on `DynamicFeesVault`.
