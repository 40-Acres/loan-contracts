---
"@40-acres/contracts": minor
---

LoanConfig: add `getMaxUtilizationBps` / `setMaxUtilizationBps` to make the legacy `CollateralManager` utilization cap configurable (previously hardcoded 80%). Reads on unset storage return the 8000 default for safe UUPS upgrades. `LoanUtils` keeps its hardcoded 80% — only the portfolio-account `CollateralManager` path is wired to the configurable cap.
