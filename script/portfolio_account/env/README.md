# Per-platform deploy env files

These files bundle the public addresses each platform needs so the per-facet
deploy scripts in `../facets/` can be run uniformly via the Makefile.

## Usage

```bash
# upgrade voting + claiming on aerodrome (Base)
make upgrade PLATFORM=aerodrome FACETS=voting,claiming

# upgrade everything you care about on velodrome
make upgrade PLATFORM=velodrome FACETS=voting,claiming,collateral,lending
```

`make upgrade` does the following:
1. `source script/portfolio_account/env/$PLATFORM.env`
2. Resolve `PORTFOLIO_FACTORY` / `LOAN_CONFIG` / `VAULT` on-chain from
   `FACTORY_SALT` via `cast`:
   - `PortfolioManager.factoryBySalt(keccak256(FACTORY_SALT))` → factory
   - `factory.portfolioFactoryConfig().getLoanConfig() / getVault()` → rest
   - Override `PORTFOLIO_MANAGER` if not using the canonical 40Acres PM.
   - Anything explicitly `export`ed in the env file wins over the derivation.
3. For each name in `FACETS`, run
   `forge script script/portfolio_account/facets/Deploy<Name>Facet.s.sol \
     --chain-id $CHAIN_ID --rpc-url ${!RPC_URL_VAR} --broadcast --verify --via-ir`

You still need `$FORTY_ACRES_DEPLOYER` and `${RPC_URL_VAR}` (e.g. `$BASE_RPC_URL`)
set in your own `.env` / shell. `cast` (Foundry) must be on `$PATH`.

## Supported facet names

The CSV value passed to `FACETS=` is matched against an alias table inside
`upgrade-facets.sh`. Names are lowercased. Currently supported:

`bridge`, `claiming`, `collateral`, `lending`, `voting`, `voting-escrow`,
`migration`, `wallet`, `marketplace`, `vexy`, `openx`,
`forty-acres-marketplace`, `rewards-processing`, `erc721-receiver`,
`erc4626-claiming`, `erc4626-collateral`, `erc4626-lending`,
`superchain-voting`, `superchain-claiming`,
`blackhole-claiming`, `blackhole-collateral`, `blackhole-voting-escrow`,
`blackhole-rewards-processing`, `blackhole-marketplace`,
`supernova-claiming`, `supernova-collateral`, `supernova-voting-escrow`,
`supernova-rewards-processing`, `supernova-marketplace`, `rewards-config`.

The `supernova-*` aliases resolve to the same scripts as `blackhole-*` —
both platforms share the Blackhole facet variants. The platform `.env` file
is what differs.

## Adding a new platform

1. Copy one of the existing `.env` files.
2. Replace addresses from the relevant `addresses/<network>/<platform>.json`
   and any external protocol docs (voting escrow, voter, rewards distributor).
3. Confirm every env var that any per-facet script reads is present — see
   `grep "vm.envAddress" ../facets/Deploy*.s.sol`.

## Platforms with custom facets

**Blackhole** (Avalanche): facet variants are wired up via the `blackhole-*`
aliases above. For facets Blackhole reuses unchanged from the standard set
(lending, voting, migration, erc721-receiver), use the plain aliases —
`make upgrade PLATFORM=blackhole FACETS=lending,voting`.

**SuperNova** (mainnet): wired up via the `supernova-*` aliases above.
SuperNova is no-loan, so VAULT resolves to zero and facets that read it will
fail by design.

## FACTORY_SALT

Every env file declares `FACTORY_SALT`, the string used at deploy time in
`portfolioManager.deployFactory(keccak256(salt))`. Known salts:

| Platform   | Loan factory      | Relayer factory |
| ---------- | ----------------- | --------------- |
| aerodrome  | `aerodrome-usdc`  | `aerodrome`     |
| velodrome  | `velodrome-usdc`  | `velodrome`     |
| blackhole  | `blackhole-usdc`  | —               |
| supernova  |                   | `supernova`     |

## Leaf chains

Chain-local overrides live in `env/chains/<chain>.env` (just CHAIN_ID,
RPC_URL_VAR, USDC, SWAP_CONFIG). Layer them onto any platform with `CHAIN=`:

```
make deploy-swap-config CHAIN=ink              # chain-only, no platform
make upgrade PLATFORM=velodrome CHAIN=ink FACETS=bridge
```

The platform env (`velodrome.env`) provides `FACTORY_SALT`, `TOKEN_MESSENGER`,
`DESTINATION_DOMAIN`, etc.; the chain env overrides anything chain-specific.
Same platform, any chain — no per-leaf env files.

Override `FACTORY_SALT=<other>` on the command line to point the wrapper at
a sibling factory under the same PortfolioManager.
