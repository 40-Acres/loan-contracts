---
"@40-acres/contracts": patch
---

Add ERC4626 rewards processing in regular and Dynamic variants. `ERC4626RewardsProcessingFacet` (regular, cached-debt `ERC4626CollateralManager`) lets yield claimed into an ERC4626 portfolio account be processed (protocol fee, lender premium, debt paydown, excess reinvest) instead of being stranded. The Dynamic family (`DynamicERC4626CollateralManager` + `DynamicERC4626CollateralFacet`/`LendingFacet`/`ClaimingFacet`/`RewardsProcessingFacet`) mirrors the YieldBasis regular/Dynamic split for ERC4626 collateral on a live-debt-read lending pool (debt read from the pool via `getDebtBalance`/`getEffectiveDebtBalance`, never cached; own storage slot). External ABIs are identical to the existing `RewardsProcessingFacet`/`ERC4626*` facets; no addresses added yet.
