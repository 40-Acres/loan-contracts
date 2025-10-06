// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IMarketOfferFacet {
    // Events
    event OfferCreated(uint256 indexed offerId, address indexed creator, uint256 minWeight, uint256 debtTolerance, uint256 price, address paymentToken, uint256 expiresAt);
    event OfferUpdated(uint256 indexed offerId, uint256 newMinWeight, uint256 newDebtTolerance, uint256 newPrice, address newPaymentToken, uint256 newExpiresAt);
    event OfferCancelled(uint256 indexed offerId);
    event OfferAccepted(uint256 indexed offerId, uint256 indexed tokenId, address indexed seller, uint256 price, uint256 fee);

    function createOffer(
        uint256 minWeight,
        uint256 debtTolerance,
        uint256 price,
        address paymentToken,
        uint256 expiresAt
    ) external payable;

    function updateOffer(
        uint256 offerId,
        uint256 newMinWeight,
        uint256 newDebtTolerance,
        uint256 newPrice,
        address newPaymentToken,
        uint256 newExpiresAt
    ) external;

    function cancelOffer(uint256 offerId) external;

    // Admin-only: cancel a batch of expired offers
    function cancelExpiredOffers(uint256[] calldata offerIds) external;

    function acceptOffer(uint256 tokenId, uint256 offerId, bool isInLoanV2, uint256 expectedPrice, address expectedPaymentToken) external;
}


