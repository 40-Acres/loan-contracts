---
"@40-acres/contracts": patch
---

ERC4626CollateralManager: value collateral via `previewRedeem` instead of `convertToAssets` so exit fees are reflected in max-loan.
