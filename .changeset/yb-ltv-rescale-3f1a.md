---
"@40-acres/contracts": major
---

Harden YieldBasis LTV branch against decimal-mismatch misconfiguration; remove dead two-layer YB pricing path from `ERC4626CollateralManager`.

- `YieldBasisCollateralManager.getMaxLoan`: in the `ltv != 0` branch, now (a) reverts with new custom error `LtvRequiresLikeToLike()` if `lendingPool.lendingAsset() != underlying`, and (b) rescales the 18-dec collateral value (from `pricePerShare`) to the lending asset's native decimals before applying LTV bps. Production yb-ETH + ETH markets (both 18-dec) are no-ops; future yb-WBTC + WBTC (both 8-dec) now compute correctly; misconfigured cross-asset LTV markets (e.g. yb-ETH + USDC with `ltv != 0`) revert at the first borrow / remove / enforce call rather than silently over-borrowing. The `ltv == 0` rewards-rate / cash-flow branch is unchanged — operator-calibrated `rewardsRate × multiplier` continues to absorb decimal+price scaling for cross-asset markets.
- `ERC4626CollateralManager`: deleted all `lpToken`-aware public overloads (`addCollateral`, `removeCollateral`, `getMaxLoan`, `getTotalCollateralValue`, `getCollateral`, `increaseTotalDebt`, `decreaseTotalDebt`, `getLoanUtilization`, `snapshotShortfall`, `enforceCollateralRequirements`, `removeSharesForYield`). These were unused in production (no facet ever passed a non-zero `lpToken`); the live YB collateral path is `YieldBasisCollateralManager`. `_resolveCollateralValue`, `_currentShortfall`, and `_snapshotIfNeeded` simplified to drop the `lpToken` parameter. `IYieldBasisLP` import removed.

ABI surface: `ERC4626CollateralManager` public selectors reduced — any external caller of the deleted overloads must migrate to `YieldBasisCollateralManager`. No registered diamond selectors were affected (the deleted overloads were library-level, never registered on a facet).
