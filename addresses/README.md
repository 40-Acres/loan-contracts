# Address Registry

Source of truth for **40Acres-deployed contracts** on every supported chain. These files are consumed by:

- Foundry deploy/upgrade scripts (`script/`) via `vm.readJson` / `vm.writeJson`
- `@40-acres/contracts` npm package generator (Phase 1)
- Homestead's `abigen` pipeline (Phase 4)

External addresses (token contracts, third-party VE contracts, USDC, etc.) do **not** belong here — they are inputs to deployments, not outputs.

## Layout

```
addresses/
├── README.md
├── addresses.json              # legacy: PortfolioManager fallback (still read by some scripts)
├── base/
│   └── aerodrome.json
├── optimism/
│   └── velodrome.json
├── avalanche/
│   ├── blackhole.json
│   └── pharaoh.json
└── mainnet/
    ├── supernova.json
    └── yieldbasis-eth.json
```

One file per `{network, platform}` pair. Network names match `viem/chains` (`base`, `optimism`, `avalanche`, `mainnet`). Platform names match the keys in [frontend protocol registry](../../frontend/src/config/protocols/index.ts).

## Schema

### V2 platforms (target architecture)

```jsonc
{
  "chainId": 8453,
  "network": "base",
  "platform": "aerodrome",
  "contracts": {
    "portfolioManager": { "dev": "0x...", "prod": "0x..." },
    "walletFactory":    { "dev": "0x...", "prod": "0x..." },
    "portfolioFactory": "0x...",                              // optional, only when no strategies (e.g. pharaoh)

    "marketplaces": {
      "native": { "dev": "0x...", "prod": "0x..." },
      "vexy":   { "dev": "0x...", "prod": "0x..." }           // optional
    },

    "strategies": {
      "usdc-loan": {                                           // strategy name = key
        "factory":     { "dev": "0x...", "prod": "0x..." },
        "config":      { "dev": "0x...", "prod": "0x..." },
        "loanConfig":  { "dev": "0x...", "prod": "0x..." },
        "supplyVault": { "dev": "0x...", "prod": "0x..." }
      },
      "relayer": {
        "factory": { "dev": "0x...", "prod": "0x..." },
        "config":  { "dev": "0x...", "prod": "0x..." }
      }
    }
  }
}
```

### V1-only platforms (no V2 deployed yet)

For platforms where V2 isn't ready (currently: blackhole), use the legacy
top-level fields and skip the V2 sections entirely:

```jsonc
{
  "chainId": 43114,
  "network": "avalanche",
  "platform": "blackhole",
  "contracts": {
    "loan":   "0x...",   // V1 loan contract
    "supply": "0x..."    // V1 supply / vault contract
  }
}
```

When V2 ships for a V1-only platform, replace this shape with the V2 schema
above — do not keep both.

### Rules

1. **An address is either a flat hex string OR `{ dev, prod }`** — never both, never partial.
   - Use `{ dev, prod }` whenever the deployment differs by environment, even if the values currently coincide. This signals intent and prevents drift.
   - Use a flat string only for addresses that are deployed once per chain (e.g. pharaoh's `portfolioFactory`).
2. **Addresses are 20-byte hex.** Lowercase preferred, checksummed accepted. The validator does not enforce checksumming.
3. **Zero address `0x0000…0000`** is reserved as the "not-deployed-yet" sentinel. The validator reports it but does not fail.
4. **V1 fields only when V2 is not yet deployed for that platform.** V2 is the target architecture and we are erasing V1 from platforms that have a V2 deployment (aerodrome, velodrome, supernova, yieldbasis-eth, pharaoh). For platforms still on V1 (currently: blackhole), use the legacy fields `loan` and `supply` at the top of `contracts`. When V2 ships for a V1 platform, replace these fields with the V2 shape — do not keep both.
5. **Keys are camelCase.** The only exception is strategy names that match the frontend (`usdc-loan`, `relayer`) — they remain hyphenated.
6. **One file per `{network, platform}` pair.** Do not create ad-hoc cross-cutting files.

### Adding a contract

1. Edit the relevant `addresses/{network}/{platform}.json` file. Add the address under `contracts` or under a strategy.
2. If this is a brand-new platform: create the file. Add an entry in this README's layout section.
3. If the address differs per env: use `{ dev, prod }`. Otherwise flat string.
4. Run the validator (Phase 0) before committing. CI will run it too.

### Adding a new chain

Create the directory `addresses/{network}/` and the first platform file inside it. Update the layout section above.

## Out of scope

- **External addresses** (token contracts, third-party VE/voter contracts, USDC) — keep in frontend's protocol configs.
- **Etherex** — no deployment in frontend config yet. Add when first deployed.
- **Blackhole V2** — not yet deployed; the V1 addresses live in [avalanche/blackhole.json](avalanche/blackhole.json) and migrate to the V2 shape once V2 ships.

## Legacy: `addresses/addresses.json`

A single-field file (`portfoliomanager`) read as a fallback by [`PortfolioHelperUtils.sol`](../script/utils/PortfolioHelperUtils.sol) and [`ApprovePool.s.sol`](../script/portfolio_account/helper/ApprovePool.s.sol). It will be removed in a later phase once those scripts are migrated to read from the chain-specific files. Do not add new fields to it.
