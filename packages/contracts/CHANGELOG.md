# @40-acres/contracts

## 0.5.0

### Minor Changes

- c06652a: Ship `bridgeFacetAbi` in the package. BridgeFacet exposes `bridge(amount, maxFee)` for direct USDC CCTP bridging and `swapMultiple(RouteParams[]) returns (uint256)` for batched non-USDC → USDC conversion (callers follow up with `bridge(...)` to send the accumulated USDC). `swapMultiple` mirrors `swapToRewardsTokenMultiple`: skips entries whose input is already USDC or is blocked by the `_isSwapAllowed` hook, and swallows per-route reverts as `SwapFailed(uint256 inputAmount, address indexed inputToken, address outputToken, address indexed owner)` events without aborting the batch.

### Patch Changes

- 8ef22b4: Harden rewards distribution config against malicious user-supplied targets.
  - `SwapConfig`: add `approvedVaults` and `approvedOutputTokens` allowlists. New owner-only setters `setApprovedVault` / `setApprovedOutputToken`, view accessors `isApprovedVault` / `isApprovedOutputToken`, and EnumerableSet getters (`getApprovedVaultsList`, `getApprovedVaultsListLength`, `getApprovedVaultAtIndex`, plus the matching OutputToken trio). Storage extended via append-only fields in the existing `keccak256("storage.SwapConfig")` slot — UUPS-safe.
  - `RewardsConfigFacet`: constructor signature changed from `(address portfolioFactory)` to `(address portfolioFactory, address swapConfig)`. All deploy scripts and test setups updated to pass the per-network `SwapConfig` address.
  - `RewardsConfigFacet.setVaultForInvesting(vault)`: now reverts with `"Vault not approved"` for any vault not registered in `SwapConfig.approvedVaults` (no zero-address bypass).
  - `RewardsConfigFacet.setZeroBalanceDistribution(entries)` and `setActiveBalanceDistribution(entry)`: now reject `InvestToVault` entries whose target is not in `approvedVaults` (`"InvestToVault target not approved"`), and `PayToRecipient` entries whose non-zero `outputToken` is not in `approvedOutputTokens` (`"PayToRecipient outputToken not approved"`). Existing `PayDebt` factory validation unchanged.

  Operational note: before this upgrade goes live on a network, the `SwapConfig` owner must seed `approvedVaults` and `approvedOutputTokens` with the protocol's intended targets. Configs saved before the upgrade keep working (validation runs only at config-set time); new `setVaultForInvesting` / distribution writes will revert until the lists are populated.

## 0.4.0

### Minor Changes

- 7e5991e: Ship raw `.abi.json` files alongside the TypeScript exports. The new `abis/` folder in the published tarball contains plain ABI JSON for each of the 26 curated contracts (`Loan.abi.json`, `PortfolioManager.abi.json`, etc.), enabling Go consumers (homestead) to feed them directly into `abigen`. TS consumers (frontend) ignore `abis/` and continue importing the typed exports unchanged.

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
