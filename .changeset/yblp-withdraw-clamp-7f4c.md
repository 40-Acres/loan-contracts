---
"@40-acres/contracts": patch
---

YieldBasisLpFacet / DynamicYieldBasisLpFacet: reconcile-first in `withdraw`, clamp `toWithdraw` to `directLp + gauge.convertToAssets(gaugeShares)`, and use `gauge.redeem(gaugeShares, ...)` instead of `gauge.withdraw(shortfall, ...)` when the request would consume the gauge's full convertToAssets value.
