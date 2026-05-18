---
"@40-acres/contracts": patch
---

YieldBasis LP collateral: split conservative TRD-aware mark from basis stamp so lender premium flow is preserved during pool imbalance, with correct decimal handling across all YB underlyings.

- `YieldBasisCollateralManager._resolveCollateralValue` now returns `min(shares × pricePerShare / 1e18, preview_withdraw(shares))`. This conservative mark is used for `getMaxLoan`, `getTotalCollateralValue`, and `enforceCollateralRequirements` (LTV / liquidation surface). When the underlying Curve pool is imbalanced ("Market TRD"), `getMaxLoan` reduces toward what a liquidator would actually recover. Same-position queries return lower values vs. previous behavior — frontend health-factor display and liquidation-bot quoters will see different numbers in stressed pool states.
- The `min()` comparison rescales `preview_withdraw`'s output to 18-dec before comparing. `pricePerShare` on the YB LT is always 18-dec normalized regardless of underlying; `preview_withdraw` returns underlying-native units. The rescale uses `IERC20Metadata(underlying).decimals()` and produces a unit-safe comparison across yb-WETH and yb-tBTC (18-dec) as well as yb-WBTC and yb-cbBTC (8-dec). Output is always 18-dec, matching the convention every downstream caller already expects.
- New `YieldBasisCollateralManager._resolveBasisValue` (pricePerShare-only, no TRD discount) backs `addCollateral`'s basis stamp and the harvest surplus calc in `YieldBasisLpClaimingFacet.harvestLpFees` / `getAvailableLpFeeYield`. Harvest stays unblocked on real pps growth regardless of TRD, so `processRewards` routing — and therefore lender premium payment — keeps flowing in imbalanced pool states. The existing 85% pps slippage floor + caller-provided `minUnderlyingPerShare` continue to guard against silent leakage on the Curve burn.
- `getAvailableLpFeeYield` view docstring updated to reflect that returned yield is pps-priced (matches the action) and that realized underlying after Curve burn is bounded by the slippage floor.

ABI signatures unchanged. Behavior change is observable: `getMaxLoan` / `getTotalCollateralValue` return TRD-discounted values during imbalance; `getAvailableLpFeeYield` and the harvest path remain pps-based and behave as they did previously.
