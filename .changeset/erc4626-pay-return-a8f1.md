---
"@40-acres/contracts": patch
---

ERC4626LendingFacet: `pay()` now returns the full unspent portion of the request (matching `BaseLendingFacet`), so cross-portfolio debt fan-out via `RewardsProcessingFacet` doesn't over-report payments to low-debt targets.
