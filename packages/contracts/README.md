# @40-acres/contracts

Typed ABIs and on-chain addresses for the 40Acres Finance protocol.

Single source of truth — generated from [loan-contracts](https://github.com/40-Acres/loan-contracts) on every release. Consumers (frontend, backend, off-chain bots) never hand-copy ABIs or addresses.

## Install

This is a private package on GitHub Packages. In the consuming repo, configure auth:

```ini
# .npmrc
@40-acres:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${GITHUB_TOKEN}
```

`GITHUB_TOKEN` needs the `read:packages` scope.

```bash
npm  install @40-acres/contracts
pnpm add     @40-acres/contracts
```

## Use

```ts
import { addresses, loanAbi, vaultAbi } from '@40-acres/contracts';
import { useReadContract } from 'wagmi';
import { parseUnits } from 'viem';

// Addresses are env-aware where deployments differ; resolve at runtime.
const env = process.env.NEXT_PUBLIC_IS_DEV === 'true' ? 'dev' : 'prod';
const supplyVault = addresses.base.aerodrome.strategies['usdc-loan'].supplyVault[env];

const { data: vaultBalance } = useReadContract({
  address: supplyVault,
  abi: vaultAbi,
  functionName: 'totalAssets',
});
```

The ABIs are exported as `as const` arrays, so wagmi/viem can fully type-check call sites — wrong function name or argument shape produces a TypeScript error at the call site, not a runtime revert.

## What ships

**ABIs** (16, all `as const`):

```
entryPointAbi          loanAbi                 portfolioFactoryAbi
facetRegistryAbi       portfolioManagerAbi     portfolioMarketplaceAbi
fortyAcresMarketplaceFacetAbi                  swapperAbi
vaultAbi               vexyFacetAbi
xPharaohLoanAbi        pharaohLoanV2Abi        pharaohLoanV2NativeAbi
pharaohSwapperAbi      etherexLoanAbi          blackholeLoanAbi
```

**Addresses** — 6 platforms across 4 networks, with dev/prod variants where deployments differ:

```
addresses.base.aerodrome
addresses.optimism.velodrome
addresses.avalanche.pharaoh
addresses.avalanche.blackhole       (V1 — V2 not yet deployed)
addresses.mainnet.supernova
addresses.mainnet.yieldbasis-eth
```

## Versioning

Semver, managed by [Changesets](https://github.com/changesets/changesets).

| Bump | When |
|---|---|
| **patch** | Address moved (redeploy of an existing contract) |
| **minor** | New address added, new contract type added |
| **major** | Address removed, ABI breaking change (function signature change, function removed) |

Changelog: [CHANGELOG.md](./CHANGELOG.md).

## License

UNLICENSED — internal use only.
