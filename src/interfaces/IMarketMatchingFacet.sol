// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IMarketMatchingFacet {
    // Events
    event OfferMatched(uint256 indexed offerId, uint256 indexed tokenId, address indexed buyer, uint256 price, uint256 fee);

    // Internal wallet-held listing: supports optional swap via ODOS
    function matchOfferWithWalletListing(
        uint256 offerId,
        uint256 tokenId,
        address inputAsset,
        uint256 maxPaymentTotal,
        uint256 maxInputAmount,
        bytes calldata tradeData,
        bytes calldata optionalPermit2
    ) external;

    // Internal loan-held listing: enforces payoff; supports optional swap via ODOS
    function matchOfferWithLoanListing(
        uint256 offerId,
        uint256 tokenId,
        address inputAsset,
        uint256 maxPaymentTotal,
        uint256 maxInputAmount,
        bytes calldata tradeData,
        bytes calldata optionalPermit2
    ) external;

    // External Vexy listing: supports optional swap via ODOS
    function matchOfferWithVexyListing(
        uint256 offerId,
        address vexy,
        uint256 listingId,
        uint256 maxPrice,
        address inputAsset,
        uint256 maxPaymentTotal,
        uint256 maxInputAmount,
        bytes calldata tradeData,
        bytes calldata optionalPermit2
    ) external;
}


