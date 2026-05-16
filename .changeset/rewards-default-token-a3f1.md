---
"@40-acres/contracts": minor
---

`VotingEscrowRewardsProcessingFacet`, `BlackholeRewardsProcessingFacet`, and `DynamicRewardsProcessingFacet`: decouple `defaultToken` from `underlyingLockedAsset` by adding a separate `defaultToken` constructor argument. All platforms (Aerodrome, Velodrome, Blackhole, SuperNova) now deploy with `defaultToken = USDC` while keeping each platform's native token as `underlyingLockedAsset`. No address changes.
