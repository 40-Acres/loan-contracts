// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IMarketListingsWalletFacet {
    // Events
    event ListingCreated(uint256 indexed tokenId, address indexed owner, uint256 price, address paymentToken, bool hasOutstandingLoan, uint256 expiresAt);
    event ListingUpdated(uint256 indexed tokenId, uint256 price, address paymentToken, uint256 expiresAt);
    event ListingCancelled(uint256 indexed tokenId);
    event ListingTaken(uint256 indexed tokenId, address indexed buyer, uint256 price, uint256 fee);

    function makeWalletListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt
    ) external;

    function updateWalletListing(
        uint256 tokenId,
        uint256 newPrice,
        address newPaymentToken,
        uint256 newExpiresAt
    ) external;

    function cancelWalletListing(uint256 tokenId) external;

    function takeWalletListing(uint256 tokenId) external payable;
}


