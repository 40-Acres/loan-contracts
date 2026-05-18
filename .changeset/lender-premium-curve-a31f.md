---
"@40-acres/contracts": major
---

`LoanConfig`: add utilization-aware lender-premium curve. New `getLenderPremium(uint256 healthLtvBps)` overload, `setLenderPremiumCurve(base, slope, kink, cap)` setter, `getLenderPremiumCurve()` view, and `LenderPremiumCurveUpdated` event. When the curve is configured (`slope != 0`), the lender premium becomes a piecewise-linear function of per-borrower LTV in bps; `slope == 0` falls back to the flat `getLenderPremium()`. Output is clamped to `cap` or to `MAX_FEE_BPS - treasuryFee` when `cap == 0`. `RewardsProcessingFacet._payLenderPremium` and `calculateRoutes` now feed the borrower's LTV (`getLoanUtilization()`) into the curve.

Breaking semantic change: `ICollateralFacet.getLoanUtilization()` and all `CollateralManager.getLoanUtilization` library functions (collateral, dynamic, ERC4626, yieldbasis) now return basis points (10_000 = at the LTV limit) instead of percent (100 = at the LTV limit). Off-chain consumers reading this value must rescale. ABI signatures are unchanged.
