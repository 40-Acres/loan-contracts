---
"@40-acres/contracts": major
---

Vault utilization cap consolidated into `LoanConfig`. `LendingVault` and `DynamicFeesVault` no longer enforce `maxUtilizationBps` on `borrowFromPortfolio` -- `setMaxUtilization(uint256)`, `maxUtilizationBps()`, `ExceedsUtilization` / `InvalidMaxUtilization` errors, and the `_maxUtilizationBps` constructor parameter are all removed. Storage slot preserved as `__deprecated_maxUtilizationBps` for UUPS upgrade safety. Enforcement moves to the borrower's manager: `DynamicCollateralManager` / `ERC4626CollateralManager` / `YieldBasisCollateralManager` now compute the cap as `vault.totalAssets() * LoanConfig.getMaxUtilizationBps() / 10000` and flag global pool overshoot into `overSuppliedVaultDebt`, which `PortfolioManager.multicall.enforceCollateralRequirements()` reverts on at end of tx.
