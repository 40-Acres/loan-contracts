---
"@40-acres/contracts": minor
---

ERC4626 collateral: add a vault-identity guard. The ERC4626 and DynamicERC4626 collateral managers now read `getCollateralVault()` from a new set-once `ERC4626PortfolioFactoryConfig` and revert `VaultMismatch` if a facet presents a different vault on the borrow side (repay stays lenient). `ERC4626CollateralFacet`/`ERC4626LendingFacet` gain the `VaultMismatch` error. Enforcement is skipped while the canonical vault is unset, so existing markets are unaffected until configured.
