---
"@40-acres/contracts": minor
---

ERC4626: add `ERC4626PortfolioFactoryConfig` with a set-once canonical `collateralVault`, and enforce it in `ERC4626CollateralManager` / `DynamicERC4626CollateralManager` so a facet bound to a different vault reverts `VaultMismatch` instead of silently reinterpreting account storage. New `getCollateralVault`/`setCollateralVault` ABI; managers unchanged in signature.
