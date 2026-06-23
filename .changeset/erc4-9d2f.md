---
"@40-acres/contracts": patch
---

ERC4626: fix `claimVaultYield` caller-side slippage floor on non-18-decimal-share vaults. `ERC4626ClaimingFacet` and `DynamicERC4626ClaimingFacet` now normalize `minAssetsPerShare` by the real share unit (`_shareUnit = 10 ** vault.decimals()`) instead of a hardcoded `1e18`. Previously, on vaults whose share token is not 18 decimals (e.g. 6d), the primary caller floor collapsed toward 0 and provided no protection. ABI/selectors and constructor signature unchanged; both facets must be redeployed.
