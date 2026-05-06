# @40-acres/contracts

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
