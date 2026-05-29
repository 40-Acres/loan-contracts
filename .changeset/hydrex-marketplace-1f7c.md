---
"@40-acres/contracts": minor
---

veHydrex marketplace on Base. Adds `marketplaces.native` (`0xd6AA…70Bc`) to `addresses/base/hydrex.json` -- the central `PortfolioMarketplace` for veHydrex listings (USDC / WETH / HYDX payment tokens, 100 bps fee). New seller-side `HydrexMarketplaceFacet` (`makeListing`, `cancelListing`, `receiveSaleProceeds`, `isListingPurchasable`, ...) routes collateral and debt through `HydrexCollateralManager`. To let the shared wallet factory buy from more than one marketplace, `FortyAcresMarketplaceFacet` gains `buyFortyAcresListingFrom(tokenId, nonce, marketplace)` (the original `buyFortyAcresListing(tokenId, nonce)` is unchanged), gated by a new `PortfolioFactoryConfig.setAllowedMarketplace` / `isAllowedMarketplace` allowlist. No Vexy / OpenX on Hydrex.
