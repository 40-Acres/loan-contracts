// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IMarketOperationsFacet {
    // ============ EVENTS ============
    event ListingCreated(uint256 indexed tokenId, address indexed owner, uint256 price, address paymentToken, bool hasOutstandingLoan, uint256 expiresAt);
    event ListingUpdated(uint256 indexed tokenId, uint256 price, address paymentToken, uint256 expiresAt);
    event ListingCancelled(uint256 indexed tokenId);
    event ListingTaken(uint256 indexed tokenId, address indexed buyer, uint256 price, uint256 fee);
    event OfferCreated(uint256 indexed offerId, address indexed creator, uint256 minWeight, uint256 maxWeight, uint256 debtTolerance, uint256 price, address paymentToken, uint256 maxLockTime, uint256 expiresAt);
    event OfferUpdated(uint256 indexed offerId, uint256 newMinWeight, uint256 newMaxWeight, uint256 newDebtTolerance, uint256 newPrice, address newPaymentToken, uint256 newMaxLockTime, uint256 newExpiresAt);
    event OfferCancelled(uint256 indexed offerId);
    event OfferAccepted(uint256 indexed offerId, uint256 indexed tokenId, address indexed seller, uint256 price, uint256 fee);
    event OfferMatched(uint256 indexed offerId, uint256 indexed tokenId, address indexed buyer, uint256 price, uint256 fee);
    event OperatorApproved(address indexed owner, address indexed operator, bool approved);

    // ============ EXTERNAL FUNCTIONS ============
    function makeListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt
    ) external;

    function updateListing(
        uint256 tokenId,
        uint256 newPrice,
        address newPaymentToken,
        uint256 newExpiresAt
    ) external;

    function cancelListing(uint256 tokenId) external;

    function takeListing(uint256 tokenId) external payable;

    function createOffer(
        uint256 minWeight,
        uint256 maxWeight,
        uint256 debtTolerance,
        uint256 price,
        address paymentToken,
        uint256 maxLockTime,
        uint256 expiresAt
    ) external payable;

    function updateOffer(
        uint256 offerId,
        uint256 newMinWeight,
        uint256 newMaxWeight,
        uint256 newDebtTolerance,
        uint256 newPrice,
        address newPaymentToken,
        uint256 newMaxLockTime,
        uint256 newExpiresAt
    ) external;

    function cancelOffer(uint256 offerId) external;

    function acceptOffer(uint256 tokenId, uint256 offerId, bool isInLoanV2) external;

    function matchOfferWithListing(uint256 offerId, uint256 tokenId) external;

    function setOperatorApproval(address operator, bool approved) external;
}


