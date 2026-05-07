# @40-acres/contracts

## 0.3.1

### Patch Changes

- 3d78d23: Document the auto-bump pipeline in the package README. End-to-end test of the Changesets release flow + cross-repo dispatch to frontend.

## 0.3.0

### Minor Changes

- 0dbd136: Add 9 facet ABIs to the package:
  - `collateralFacetAbi`, `erc4626CollateralFacetAbi` — collateral management
    (addCollateral, removeCollateral, getLockedCollateral, etc.)
  - `erc4626LendingFacetAbi` — borrow, getTotalDebt
  - `rewardsProcessingFacetAbi` — pay
  - `yieldBasisLpFacetAbi` — deposit, withdraw
  - `veYieldBasisFacetAbi` — createLock, increaseLock
  - `dynamicVotingEscrowFacetAbi` — merge, mergeInternal
  - `votingFacetAbi` — batchVote, setVotingMode
  - `xPharaohFacetAbi` — Pharaoh's V1 facet (xPhar\* methods),
    still actively used in production despite living under `src/legacy/`.

  Replaces the frontend's hand-typed `FACETS_ABI` (a synthetic union over
  the diamond proxy) with individual facet ABIs that consumers pick per
  call site. Also unblocks the migration of `phar_abi.ts` to the package.

## 0.2.0

### Minor Changes

- 9b76ac5: Add `walletFacetAbi` (per-user account utilities: `receiveERC20`,
  `transferERC20`, `transferNFT`, `withdrawERC20`, `swap`,
  `enforceCollateralRequirements`, `onERC721Received`).

  Frontend can now consume this ABI directly via
  `import { walletFacetAbi } from '@40-acres/contracts'` instead of the
  hand-typed `WALLET_FACET_ABI` in `src/abi/wallet_facet_abi.ts`.

## 0.1.0

### Minor Changes

- b801bde: Initial release.

  Establishes the contracts package as the single source of truth for
  40Acres on-chain addresses and ABIs. Ships:
  - 16 typed `as const` ABIs (loan, vault, entryPoint, swapper, the V2
    portfolio account architecture, marketplaces, and the per-platform
    Pharaoh / Etherex / Blackhole adapters)
  - The `addresses` tree for 6 platforms across 4 networks (V2 where
    deployed, V1 fallback for Blackhole until V2 ships there), with
    `{ dev, prod }` env-aware variants matching the frontend's pattern

  Consumers should follow `packages/contracts/README.md` for `.npmrc`
  setup against GitHub Packages.
