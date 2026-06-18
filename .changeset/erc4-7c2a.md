---
"@40-acres/contracts": minor
---

ERC4626CollateralFacet: add `removeCollateralTo(uint256,address)`, which removes vault shares from collateral and transfers them to the owner's account in a target (registered) portfolio factory, creating that account if absent.
