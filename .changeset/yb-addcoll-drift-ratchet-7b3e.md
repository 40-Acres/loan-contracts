---
"@40-acres/contracts": patch
---

YieldBasis collateral managers: fix `addCollateral` deadlock when gauge `convertToAssets` drift left tracked shares above actually-recoverable LP. The in-block snapshot now subtracts the incoming deposit from the observed LP balance before ratcheting, so deposits always succeed when LP is actually transferred. Tracked shares and basis end at the truth (`actual + shares`, basis haircut proportionally so per-share basis is preserved). Mirrored across `YieldBasisCollateralManager` and `DynamicYieldBasisCollateralManager`.
