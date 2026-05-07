# @40-acres/contracts

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
