---
"@40-acres/contracts": major
---

LoanConfig: extend the lender-premium curve to two slopes. `setLenderPremiumCurve` now takes a 5th `slopeBelow` arg (ramp below the kink; existing `slope` stays the above-kink ramp) and `getLenderPremiumCurve` returns the matching 5-tuple. `getLenderPremium(ltv)` now ramps below the kink instead of staying flat at `base`; the curve disables (flat `lenderPremium`) only when both slopes are 0. Setter validates `slopeBelow <= MAX_LENDER_PREMIUM_SLOPE` and `slopeBelow <= slope` (curve must steepen past the kink). `LenderPremiumCurveUpdated` event gains a `slopeBelow` field. Existing deployed curves are unaffected (new field defaults to 0 = current flat-below-kink behavior). ABI changed: `setLenderPremiumCurve`, `getLenderPremiumCurve`, `LenderPremiumCurveUpdated`.
