// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IVexyAdapterFacet {
    event VexyListingPurchased(
        address indexed marketplace,
        uint256 indexed listingId,
        address indexed nftCollection,
        uint256 nftId,
        address buyer,
        address currency,
        uint256 price
    );

    /// @notice Buy an external Vexy marketplace listing and deliver the NFT to msg.sender
    /// @param marketplace Address of the VexyMarketplace contract
    /// @param listingId Listing id in the external marketplace
    /// @param expectedCurrency Payment token expected (must be allowed by market)
    /// @param maxPrice Max price willing to pay (slippage bound vs. Vexy dynamic price)
    /// @dev This function is only callable by the diamond contract
    function takeVexyListing(
        address marketplace,
        uint256 listingId,
        address expectedCurrency,
        uint256 maxPrice
    ) external;

}


