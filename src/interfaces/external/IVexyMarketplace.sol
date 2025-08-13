// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IVexyMarketplace {
    struct Listing {
        address seller;
        uint96 sellerNftNonce;
        address nftCollection;
        uint256 nftId;
        address currency;
        uint96 slopeMax;
        uint256 price;
        uint32 slopeDuration;
        uint32 fixedDuration;
        uint64 endTime;
        uint64 soldTime;
    }

    function listingsLength() external view returns (uint256);

    function listingPrice(uint256 listingId) external view returns (uint256);

    function listings(uint256 listingId)
        external
        view
        returns (
            address seller,
            uint96 sellerNftNonce,
            address nftCollection,
            uint256 nftId,
            address currency,
            uint96 slopeMax,
            uint256 price,
            uint32 slopeDuration,
            uint32 fixedDuration,
            uint64 endTime,
            uint64 soldTime
        );

    function buyListing(uint256 listingId) external;

    function sellerNftNonce(address seller, address collection, uint256 nftId) external view returns (uint96);
}


