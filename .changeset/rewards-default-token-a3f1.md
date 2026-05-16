---
"@40-acres/contracts": minor
---

`VotingEscrowRewardsProcessingFacet`, `BlackholeRewardsProcessingFacet`, and `DynamicRewardsProcessingFacet`: decouple `defaultToken` from `underlyingLockedAsset` by adding a separate `defaultToken` constructor argument. SuperNova will deploy with `defaultToken = USDC` and `underlyingLockedAsset = NOVA`; existing platforms (Aerodrome, Velodrome, Blackhole) pass the same address for both args to preserve current behavior. No address changes.
