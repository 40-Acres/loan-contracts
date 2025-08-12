// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IMarketMatchingFacet {
    // Events
    event OfferMatched(uint256 indexed offerId, uint256 indexed tokenId, address indexed buyer, uint256 price, uint256 fee);

    function matchOfferWithLoanListing(uint256 offerId, uint256 tokenId) external;
    function matchOfferWithWalletListing(uint256 offerId, uint256 tokenId) external;
}


