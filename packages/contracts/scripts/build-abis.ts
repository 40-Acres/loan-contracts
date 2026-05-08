#!/usr/bin/env tsx
/**
 * Reads Foundry build artifacts under `out/<source>.sol/<contract>.json` and
 * emits raw `.abi.json` files to `packages/contracts/abis/<contract>.abi.json`.
 *
 * Why ship raw JSON when wagmi-cli already produces TS exports?
 *   Go consumers (homestead) need plain `.abi` JSON to feed into `abigen`.
 *   The TS `as const` shape is unusable from Go. Bundling raw JSON in the
 *   same npm package keeps frontend (TS) and homestead (Go) versioned
 *   together with no second publish artifact to manage.
 *
 * Curated list mirrors `wagmi.config.ts` -- when adding a contract there,
 * add it here too. The lists are intentionally NOT deduplicated to keep
 * each file self-contained and readable.
 *
 * Run from the workspace root:  pnpm build:abi-json
 */
import { mkdirSync, readFileSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const repoRoot = join(__dirname, '..', '..', '..');
const foundryOut = join(repoRoot, 'out');
const abisDir = join(repoRoot, 'packages', 'contracts', 'abis');

// Keep in sync with `wagmi.config.ts`. Each entry is the artifact path under
// `out/`, formatted as `<source>.sol/<Contract>.json`.
const ARTIFACTS = [
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

  // Wallet facet
  'WalletFacet.sol/WalletFacet.json',

  // Diamond facets
  'ERC4626LendingFacet.sol/ERC4626LendingFacet.json',
  'RewardsProcessingFacet.sol/RewardsProcessingFacet.json',
  'YieldBasisLpFacet.sol/YieldBasisLpFacet.json',
  'CollateralFacet.sol/CollateralFacet.json',
  'ERC4626CollateralFacet.sol/ERC4626CollateralFacet.json',
  'DynamicVotingEscrowFacet.sol/DynamicVotingEscrowFacet.json',
  'veYieldBasisFacet.sol/veYieldBasisFacet.json',
  'VotingFacet.sol/VotingFacet.json',

  // XPharaohFacet (V1, still in production)
  'XPharaohFacet.sol/XPharaohFacet.json',

  // Pharaoh adapter
  'XPharaohLoan.sol/XPharaohLoan.json',
  'PharaohLoanV2.sol/PharaohLoanV2.json',
  'PharaohLoanV2Native.sol/PharaohLoanV2Native.json',
  'PharaohSwapper.sol/PharaohSwapper.json',

  // Etherex adapter
  'EtherexLoan.sol/EtherexLoan.json',

  // Blackhole adapter (V1)
  'BlackholeLoan.sol/BlackholeLoan.json',
];

function build() {
  // Wipe and recreate so removed artifacts don't linger as stale files.
  if (existsSync(abisDir)) rmSync(abisDir, { recursive: true });
  mkdirSync(abisDir, { recursive: true });

  let written = 0;
  const missing: string[] = [];
  for (const artifact of ARTIFACTS) {
    const artifactPath = join(foundryOut, artifact);
    if (!existsSync(artifactPath)) {
      missing.push(artifact);
      continue;
    }

    const json = JSON.parse(readFileSync(artifactPath, 'utf8'));
    if (!Array.isArray(json.abi)) {
      console.error(`Artifact ${artifact} has no .abi field or it's not an array`);
      process.exit(1);
    }

    // Contract name is the filename minus .json -- matches Foundry's
    // contract name and homestead's existing naming convention
    // (e.g. PortfolioManager.abi).
    const contract = artifact.split('/').pop()!.replace(/\.json$/, '');
    const outPath = join(abisDir, `${contract}.abi.json`);
    writeFileSync(outPath, JSON.stringify(json.abi, null, 2) + '\n');
    written++;
  }

  if (missing.length > 0) {
    console.error('Missing Foundry artifacts (run `forge build` first):');
    for (const m of missing) console.error(`  - ${m}`);
    process.exit(1);
  }

  console.log(`Wrote ${written} ABI file(s) to ${abisDir}`);
}

build();
