---
"@40-acres/contracts": minor
---

Ship raw `.abi.json` files alongside the TypeScript exports. The new `abis/` folder in the published tarball contains plain ABI JSON for each of the 26 curated contracts (`Loan.abi.json`, `PortfolioManager.abi.json`, etc.), enabling Go consumers (homestead) to feed them directly into `abigen`. TS consumers (frontend) ignore `abis/` and continue importing the typed exports unchanged.
