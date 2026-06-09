# @40-acres/contracts

## 2.0.0

### Major Changes

- be4a2fe: LoanConfig: extend the lender-premium curve to two slopes. `setLenderPremiumCurve` now takes a 5th `slopeBelow` arg (ramp below the kink; existing `slope` stays the above-kink ramp) and `getLenderPremiumCurve` returns the matching 5-tuple. `getLenderPremium(ltv)` now ramps below the kink instead of staying flat at `base`; the curve disables (flat `lenderPremium`) only when both slopes are 0. Setter validates `slopeBelow <= MAX_LENDER_PREMIUM_SLOPE` and `slopeBelow <= slope` (curve must steepen past the kink). `LenderPremiumCurveUpdated` event gains a `slopeBelow` field. Existing deployed curves are unaffected (new field defaults to 0 = current flat-below-kink behavior). ABI changed: `setLenderPremiumCurve`, `getLenderPremiumCurve`, `LenderPremiumCurveUpdated`.

### Patch Changes

- 8fb0c87: CollateralManager (+ DynamicCollateralManager, HydrexCollateralManager, DynamicHydrexCollateralManager): fix `undercollateralizedDebt`. Removed the `previousMaxLoanIgnoreSupply == newMaxLoanIgnoreSupply` branch in `_updateUndercollateralizedDebt` that persisted the full debt-minus-maxLoan shortfall during a no-capacity-change collateral sync (e.g. reward compounding via `updateLockedCollateral`), which left the counter non-zero at rest. Restores multicall-local delta-tracker semantics. ABI unchanged. Velodrome (Optimism) redeploy of the collateral-linked facets to follow.

## 1.2.0

### Minor Changes

- 68cb429: Ship the Hydrex marketplace buyer code that 1.1.0's changelog described ahead of the merge (landed in #232). `FortyAcresMarketplaceFacet.buyFortyAcresListingFrom(tokenId, nonce, marketplace)` — allowlist-gated via `PortfolioFactoryConfig.setAllowedMarketplace` / `isAllowedMarketplace` — lets the shared Base portfolio diamond purchase from non-aerodrome marketplaces (required for portfolio-mode buys of veHydrex listings on the central PortfolioMarketplace `0xd6AAa9…70Bc`). The original `buyFortyAcresListing(tokenId, nonce)` is unchanged. Regenerates the package ABI so `fortyAcresMarketplaceFacetAbi` exposes `buyFortyAcresListingFrom`, which downstream consumers (frontend portfolio-buy flow) need.

## 1.1.0

### Minor Changes

- f308e7f: Hydrex on base: simplify rebase-bucket lifecycle. `VeHydrexClaimingFacet.claimRebase` now uses `RewardsDistributorV2.claimInto` to deposit non-PERMANENT-source rebase value directly into the account's existing bucket lock (no fresh mint, no merge). PERMANENT-source claims short-circuit to plain `claim()` since Hydrex auto-applies in place. First-time-seed mint still mints once to create the bucket. `VeHydrexVotingEscrowFacet` receiver hook no longer merges incoming PERMANENT veNFTs into the bucket — each is tracked as its own collateral entry; the first one (if no bucket yet) also gets designated as the bucket. `RebaseClaimed.amount` now reflects the actually-deposited value via `claimInto`'s return (previously emitted a pre-snapshot `claimable` that could undercount). Removes `HydrexBucketLib` and `RebaseBucketAbsorbed` event.
- e50a204: veHydrex marketplace on Base. Adds `marketplaces.native` (`0xd6AA…70Bc`) to `addresses/base/hydrex.json` -- the central `PortfolioMarketplace` for veHydrex listings (USDC / WETH / HYDX payment tokens, 100 bps fee). New seller-side `HydrexMarketplaceFacet` (`makeListing`, `cancelListing`, `receiveSaleProceeds`, `isListingPurchasable`, ...) routes collateral and debt through `HydrexCollateralManager`. To let the shared wallet factory buy from more than one marketplace, `FortyAcresMarketplaceFacet` gains `buyFortyAcresListingFrom(tokenId, nonce, marketplace)` (the original `buyFortyAcresListing(tokenId, nonce)` is unchanged), gated by a new `PortfolioFactoryConfig.setAllowedMarketplace` / `isAllowedMarketplace` allowlist. No Vexy / OpenX on Hydrex.
- e50a204: Velodrome (optimism): add `marketplaces.vexy` (`0x6b47…6738`) to the address registry, matching the Aerodrome (base) Vexy marketplace entry. Pairs with on-chain registration of `VexyFacet` (`buyVexyListing`), `FortyAcresMarketplaceFacet` (`buyFortyAcresListing`), and the missing `isListingPurchasable` selector on the existing `MarketplaceFacet`.

### Patch Changes

- 492be4a: DynamicFeesVault: `totalAssets()` now simulates pending reward-stream vesting so ERC4626 preview/max views match the values mint/burn would see after settlement. Closes a stale-NAV gap where mid-epoch depositors could capture the already-vested fraction of lender premium they did not fund.
- f29bed1: ERC4626CollateralManager: value collateral via `previewRedeem` instead of `convertToAssets` so exit fees are reflected in max-loan.
- f29bed1: ERC4626LendingFacet: `pay()` now returns the full unspent portion of the request (matching `BaseLendingFacet`), so cross-portfolio debt fan-out via `RewardsProcessingFacet` doesn't over-report payments to low-debt targets.
- e50a204: ERC4626 + YieldBasis collateral managers (ERC4626CollateralManager, YieldBasisCollateralManager, DynamicYieldBasisCollateralManager): `removeCollateral` now reverts `BelowMinimumCollateral` when a partial withdrawal would leave live collateral value in (0, `getMinimumCollateral()`); full exits (remaining value 0) still allowed. No-op when the minimum is unset (0). Reuses the existing single minimum config and applies regardless of debt. ABI unchanged (adds an error only).
- f29bed1: YieldBasis collateral managers: fix `addCollateral` deadlock when gauge `convertToAssets` drift left tracked shares above actually-recoverable LP. The in-block snapshot now subtracts the incoming deposit from the observed LP balance before ratcheting, so deposits always succeed when LP is actually transferred. Tracked shares and basis end at the truth (`actual + shares`, basis haircut proportionally so per-share basis is preserved). Mirrored across `YieldBasisCollateralManager` and `DynamicYieldBasisCollateralManager`.
- f29bed1: YieldBasisLpFacet / DynamicYieldBasisLpFacet: reconcile-first in `withdraw`, clamp `toWithdraw` to `directLp + gauge.convertToAssets(gaugeShares)`, and use `gauge.redeem(gaugeShares, ...)` instead of `gauge.withdraw(shortfall, ...)` when the request would consume the gauge's full convertToAssets value.

## 1.0.0

### Major Changes

- 8e28d47: `LoanConfig`: add utilization-aware lender-premium curve. New `getLenderPremium(uint256 healthLtvBps)` overload, `setLenderPremiumCurve(base, slope, kink, cap)` setter, `getLenderPremiumCurve()` view, and `LenderPremiumCurveUpdated` event. When the curve is configured (`slope != 0`), the lender premium becomes a piecewise-linear function of per-borrower LTV in bps; `slope == 0` falls back to the flat `getLenderPremium()`. Output is clamped to `cap` or to `MAX_FEE_BPS - treasuryFee` when `cap == 0`. `RewardsProcessingFacet._payLenderPremium` and `calculateRoutes` now feed the borrower's LTV (`getLoanUtilization()`) into the curve.

  Breaking semantic change: `ICollateralFacet.getLoanUtilization()` and all `CollateralManager.getLoanUtilization` library functions (collateral, dynamic, ERC4626, yieldbasis) now return basis points (10_000 = at the LTV limit) instead of percent (100 = at the LTV limit). Off-chain consumers reading this value must rescale. ABI signatures are unchanged.

- 1b82cab: Vault utilization cap consolidated into `LoanConfig`. `LendingVault` and `DynamicFeesVault` no longer enforce `maxUtilizationBps` on `borrowFromPortfolio` -- `setMaxUtilization(uint256)`, `maxUtilizationBps()`, `ExceedsUtilization` / `InvalidMaxUtilization` errors, and the `_maxUtilizationBps` constructor parameter are all removed. Storage slot preserved as `__deprecated_maxUtilizationBps` for UUPS upgrade safety. Enforcement moves to the borrower's manager: `DynamicCollateralManager` / `ERC4626CollateralManager` / `YieldBasisCollateralManager` now compute the cap as `vault.totalAssets() * LoanConfig.getMaxUtilizationBps() / 10000` and flag global pool overshoot into `overSuppliedVaultDebt`, which `PortfolioManager.multicall.enforceCollateralRequirements()` reverts on at end of tx.
- 4770c91: Harden YieldBasis LTV branch against decimal-mismatch misconfiguration; remove dead two-layer YB pricing path from `ERC4626CollateralManager`.
  - `YieldBasisCollateralManager.getMaxLoan`: in the `ltv != 0` branch, now (a) reverts with new custom error `LtvRequiresLikeToLike()` if `lendingPool.lendingAsset() != underlying`, and (b) rescales the 18-dec collateral value (from `pricePerShare`) to the lending asset's native decimals before applying LTV bps. Production yb-ETH + ETH markets (both 18-dec) are no-ops; future yb-WBTC + WBTC (both 8-dec) now compute correctly; misconfigured cross-asset LTV markets (e.g. yb-ETH + USDC with `ltv != 0`) revert at the first borrow / remove / enforce call rather than silently over-borrowing. The `ltv == 0` rewards-rate / cash-flow branch is unchanged — operator-calibrated `rewardsRate × multiplier` continues to absorb decimal+price scaling for cross-asset markets.
  - `ERC4626CollateralManager`: deleted all `lpToken`-aware public overloads (`addCollateral`, `removeCollateral`, `getMaxLoan`, `getTotalCollateralValue`, `getCollateral`, `increaseTotalDebt`, `decreaseTotalDebt`, `getLoanUtilization`, `snapshotShortfall`, `enforceCollateralRequirements`, `removeSharesForYield`). These were unused in production (no facet ever passed a non-zero `lpToken`); the live YB collateral path is `YieldBasisCollateralManager`. `_resolveCollateralValue`, `_currentShortfall`, and `_snapshotIfNeeded` simplified to drop the `lpToken` parameter. `IYieldBasisLP` import removed.

  ABI surface: `ERC4626CollateralManager` public selectors reduced — any external caller of the deleted overloads must migrate to `YieldBasisCollateralManager`. No registered diamond selectors were affected (the deleted overloads were library-level, never registered on a facet).

- 120bcb5: YieldBasis ETH: introduce DynamicYieldBasisCollateralManager + four Dynamic LP facets (`DynamicYieldBasisLpFacet`, `DynamicYieldBasisLpLendingFacet`, `DynamicYieldBasisLpClaimingFacet`, `DynamicYieldBasisLpRewardsProcessingFacet`) for use against vaults that mutate debt outside borrow/pay (DynamicFeesVault and future variants). Manager reads debt live from the pool each call (raw via `getDebtBalance` for solvency reverts, effective via `getEffectiveDebtBalance` for headroom/UX); separate storage slot from the legacy YieldBasisCollateralManager. Lending facet adds `nonReentrant` on borrow/pay/topUp sharing the slot with the claiming facet. New deploy script redeploys the ybETH/WETH `supplyVault` as a fresh DynamicFeesVault on mainnet prod (`0x204b…4Ba3` -> `0xB543…e4A1`, WETH asset, feeBps=0, feeRecipient=0x5FB61F8fC6d8C5767A2B937578A49A1869d0bDa8) and re-registers the four facets via FacetRegistry.

### Minor Changes

- d12844f: Portfolio accounts: add configurable treasury address (`setTreasury`/`getTreasury` + `TreasuryUpdated` event) to `LoanConfig`, `LendingVault`, and `DynamicFeesVault`. Protocol fees, origination fees, zero-balance fees, and the claim-flow treasury fee now route to `LoanConfig.getTreasury()` (or the vault's own `getTreasury()` for vault-collected fees) instead of `owner()`. Unset treasury falls back to `owner()`, preserving existing deployment behavior.
- 120bcb5: Hydrex (Base): register `hydrex` platform with `usdc-loan` strategy — factory `0x7448…a7D6`, config `0xC473…284f`, loanConfig `0x6628…8ffc`, votingConfig `0xc694…0887`, supplyVault `0x16eD…b474`. PortfolioManager re-uses Aerodrome prod (`0x40Ac…29ec`).
- 120bcb5: Hydrex (Base): add veHydrex account facets (`VeHydrexFacet`, `VeHydrexClaimingFacet`, `VeHydrexVotingEscrowFacet`) plus their `Dynamic*` variants under `src/facets/account/veHydrex/`. Voting is account-wide (Hydrex's Voter auto-resets), claim entry points cover fees/bribes and rebase, and a per-account rebase-bucket pattern (tracked on `HydrexPortfolioFactoryConfig`) absorbs the fresh PERMANENT veNFT that Hydrex's RewardsDistributor mints for non-PERMANENT originals. ROLLING + PERMANENT lock types only; NON_PERMANENT deposits auto-convert to ROLLING in the receiver hook. Also adds `HydrexCollateralManager` / `DynamicHydrexCollateralManager` (distinct storage slots, `lockDetails`-based reads) plus the supporting `DynamicHydrexCollateralFacet` / `DynamicHydrexLendingFacet` / `DynamicHydrexRewardsProcessingFacet` so a Hydrex diamond can be deployed end to end on `DynamicFeesVault`.
- a6882e5: LoanConfig: add `getMaxUtilizationBps` / `setMaxUtilizationBps` to make the legacy `CollateralManager` utilization cap configurable (previously hardcoded 80%). Reads on unset storage return the 8000 default for safe UUPS upgrades. `LoanUtils` keeps its hardcoded 80% — only the portfolio-account `CollateralManager` path is wired to the configurable cap.
- 757c38b: `VotingEscrowRewardsProcessingFacet`, `BlackholeRewardsProcessingFacet`, and `DynamicRewardsProcessingFacet`: decouple `defaultToken` from `underlyingLockedAsset` by adding a separate `defaultToken` constructor argument. All platforms (Aerodrome, Velodrome, Blackhole, SuperNova) now deploy with `defaultToken = USDC` while keeping each platform's native token as `underlyingLockedAsset`. No address changes.

### Patch Changes

- 1de1ff1: DynamicFeesVault: gate `borrowFromPortfolio` and `activeAssets()` against effective debt (`totalLoanedAssets` net of `totalVestedRewardsApplied + globalBorrowerPending`) instead of raw `totalLoanedAssets`. Fixes drift that collapsed borrow capacity over time as reward settlement reduced debt without reducing `totalLoanedAssets`. ABI unchanged.
- 71305cb: DynamicFeesVault: at the epoch boundary inside `_processGlobalVesting`, consume any residual `totalUnsettledRewards` (floor-division dust from `depositRewards`) into the same lender-premium / borrower-credit split as the rest of the vested amount. Previously dust accumulated indefinitely and was permanently subtracted from `totalAssets()`, slightly understating NAV and inflating measured utilization. ABI unchanged.
- a3ea439: LendingVault: fix JIT sandwich on mid-epoch `depositRewards`. Mid-epoch deposits now contribute `amount * WEEK / remaining` to `currentEpochRewards`, so `totalAssets()` stays invariant at the moment of deposit and the reward vests linearly from now until epoch end. Appended `currentEpochActualRewards` storage slot; `lastEpochReward()` reads from it for a truthful per-epoch token count. ABI unchanged.
- bec0f45: LendingVault & DynamicFeesVault: revert `borrowFromPortfolio` when `totalAssets() == 0` and tighten the utilization cap to a strict-inequality multiplication form. Previously a zero-supply vault treated utilization as 0% and allowed borrows past the cap. No ABI change.
- 120bcb5: YieldBasis: `getTotalCollateralValue` and `_snapshotIfNeeded` now reconcile `data.shares` against actual recoverable LP (direct balance + gauge `convertToAssets`) before pricing and shortfall computation. Closes a defense-in-depth gap where a gauge drift between deposit and the next admin reconcile could let a borrower draw against phantom shares. Also: `DynamicYieldBasisLpLendingFacet.borrow` gains a `nonReentrant` guard to match `pay`/`topUp`. No ABI changes.
- 62000d8: YieldBasis LP collateral: split conservative TRD-aware mark from basis stamp so lender premium flow is preserved during pool imbalance, with correct decimal handling across all YB underlyings.
  - `YieldBasisCollateralManager._resolveCollateralValue` now returns `min(shares × pricePerShare / 1e18, preview_withdraw(shares))`. This conservative mark is used for `getMaxLoan`, `getTotalCollateralValue`, and `enforceCollateralRequirements` (LTV / liquidation surface). When the underlying Curve pool is imbalanced ("Market TRD"), `getMaxLoan` reduces toward what a liquidator would actually recover. Same-position queries return lower values vs. previous behavior — frontend health-factor display and liquidation-bot quoters will see different numbers in stressed pool states.
  - The `min()` comparison rescales `preview_withdraw`'s output to 18-dec before comparing. `pricePerShare` on the YB LT is always 18-dec normalized regardless of underlying; `preview_withdraw` returns underlying-native units. The rescale uses `IERC20Metadata(underlying).decimals()` and produces a unit-safe comparison across yb-WETH and yb-tBTC (18-dec) as well as yb-WBTC and yb-cbBTC (8-dec). Output is always 18-dec, matching the convention every downstream caller already expects.
  - New `YieldBasisCollateralManager._resolveBasisValue` (pricePerShare-only, no TRD discount) backs `addCollateral`'s basis stamp and the harvest surplus calc in `YieldBasisLpClaimingFacet.harvestLpFees` / `getAvailableLpFeeYield`. Harvest stays unblocked on real pps growth regardless of TRD, so `processRewards` routing — and therefore lender premium payment — keeps flowing in imbalanced pool states. The existing 85% pps slippage floor + caller-provided `minUnderlyingPerShare` continue to guard against silent leakage on the Curve burn.
  - `getAvailableLpFeeYield` view docstring updated to reflect that returned yield is pps-priced (matches the action) and that realized underlying after Curve burn is bounded by the slippage floor.

  ABI signatures unchanged. Behavior change is observable: `getMaxLoan` / `getTotalCollateralValue` return TRD-discounted values during imbalance; `getAvailableLpFeeYield` and the harvest path remain pps-based and behave as they did previously.

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
