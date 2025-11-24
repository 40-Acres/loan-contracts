// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IOpenXAdapterFacet {
    event OpenXListingPurchased(
        address indexed marketplace,
        uint256 indexed listingId,
        address indexed veNft,
        uint256 tokenId,
        address buyer,
        address currency,
        uint256 price
    );

    function takeOpenXListing(
        address marketplace,
        uint256 listingId,
        address expectedCurrency,
        uint256 maxPrice
    ) external;
}


