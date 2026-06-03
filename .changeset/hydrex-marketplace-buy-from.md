---
"@40-acres/contracts": minor
---

Ship the Hydrex marketplace buyer code that 1.1.0's changelog described ahead of the merge (landed in #232). `FortyAcresMarketplaceFacet.buyFortyAcresListingFrom(tokenId, nonce, marketplace)` — allowlist-gated via `PortfolioFactoryConfig.setAllowedMarketplace` / `isAllowedMarketplace` — lets the shared Base portfolio diamond purchase from non-aerodrome marketplaces (required for portfolio-mode buys of veHydrex listings on the central PortfolioMarketplace `0xd6AAa9…70Bc`). The original `buyFortyAcresListing(tokenId, nonce)` is unchanged. Regenerates the package ABI so `fortyAcresMarketplaceFacetAbi` exposes `buyFortyAcresListingFrom`, which downstream consumers (frontend portfolio-buy flow) need.
