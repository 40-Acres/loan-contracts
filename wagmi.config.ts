import { defineConfig } from '@wagmi/cli';
import { foundry } from '@wagmi/cli/plugins';

// wagmi-cli reads Foundry build artifacts from `out/` and emits typed,
// `as const`-suffixed ABIs into the package. Run `forge build` first.
//
// We use an explicit `include` list rather than glob-include + exclude
// because the codebase has many duplicate contract/interface names across
// per-platform adapter directories (Pharaoh/, Etherex/, Blackhole/) and
// V1/V2 pairs. Curating the surface intentionally:
//   - keeps the package's public ABI surface visible at a glance
//   - prevents accidental publication of test/script/internal contracts
//   - sidesteps name collisions that Foundry tolerates but wagmi-cli rejects
//
// To add a new contract type (Case B in the contracts-package design):
//   1. Add the artifact path below (relative to `out/`).
//   2. Run `pnpm build:abis` and confirm the new export appears in
//      `packages/contracts/src/generated.ts`.
//
// Patterns are globs against the artifact path under `out/`.

export default defineConfig({
  out: 'packages/contracts/src/generated.ts',
  plugins: [
    foundry({
      project: '.',
      include: [
        // Core contracts
        'LoanV2.sol/Loan.json',
        'VaultV2.sol/Vault.json',
        'EntryPoint.sol/EntryPoint.json',
        'Swapper.sol/Swapper.json',

        // V2 portfolio account architecture
        'PortfolioManager.sol/PortfolioManager.json',
        'PortfolioFactory.sol/PortfolioFactory.json',
        'FacetRegistry.sol/FacetRegistry.json',

        // Marketplaces
        'PortfolioMarketplace.sol/PortfolioMarketplace.json',
        'FortyAcresMarketplaceFacet.sol/FortyAcresMarketplaceFacet.json',
        'VexyFacet.sol/VexyFacet.json',
        // Note: VexyMarketplace is third-party (not in our src/). The frontend
        // ships its own copy of that ABI; it does not belong here.

        // Wallet facet (per-user account utilities: receiveERC20,
        // transferERC20, transferNFT, withdrawERC20, swap).
        // Frontend consumes this via portfolio-operations/operations/wallet.ts.
        'WalletFacet.sol/WalletFacet.json',

        // Diamond facets exposed via the portfolio account proxy.
        // Frontend currently has these methods union-typed in src/abi/facets_abi.ts;
        // shipping the individual facet ABIs lets consumers pick per call site
        // (e.g. lendingFacetAbi for borrow(), votingFacetAbi for batchVote()).
        'ERC4626LendingFacet.sol/ERC4626LendingFacet.json',
        'RewardsProcessingFacet.sol/RewardsProcessingFacet.json',
        'YieldBasisLpFacet.sol/YieldBasisLpFacet.json',
        'CollateralFacet.sol/CollateralFacet.json',
        'ERC4626CollateralFacet.sol/ERC4626CollateralFacet.json',
        'DynamicVotingEscrowFacet.sol/DynamicVotingEscrowFacet.json',
        'veYieldBasisFacet.sol/veYieldBasisFacet.json',
        'VotingFacet.sol/VotingFacet.json',

        // XPharaohFacet -- Pharaoh's V1 facet, still active in production
        // (Pharaoh's V1 is NOT being erased like other platforms). Lives in
        // src/legacy/ for historical organization but functionally current.
        'XPharaohFacet.sol/XPharaohFacet.json',

        // Pharaoh adapter (Avalanche). PharaohVault is just `contract Vault
        // is VaultV2` -- a thin wrapper, so we don't ship it (VaultV2 above
        // is the parent). PharaohLoan (V1) is dropped per the V1-erasure plan.
        'XPharaohLoan.sol/XPharaohLoan.json',
        'PharaohLoanV2.sol/PharaohLoanV2.json',
        'PharaohLoanV2Native.sol/PharaohLoanV2Native.json',
        'PharaohSwapper.sol/PharaohSwapper.json',

        // Etherex adapter (extends XPharaohLoan). Frontend imports the ABI
        // today as REX_LOAN_ABI in src/abi/protocols/rex_abi.ts.
        'EtherexLoan.sol/EtherexLoan.json',

        // Blackhole adapter (Avalanche). V1 only -- V2 not yet deployed there
        // (see addresses/avalanche/blackhole.json). When BlackholeLoanV2
        // ships, add 'BlackholeLoanV2.sol/BlackholeLoanV2.json' here.
        'BlackholeLoan.sol/BlackholeLoan.json',
      ],
    }),
  ],
});
