// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IMarketViewFacet {
    // State getters
    function loan() external view returns (address);
    function marketFeeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);
    function loanAsset() external view returns (address);
    function isOperatorFor(address owner, address operator) external view returns (bool);
    function allowedPaymentToken(address token) external view returns (bool);

    // Views
    function getListing(uint256 tokenId) external view returns (
        address owner,
        uint256 price,
        address paymentToken,
        bool hasOutstandingLoan,
        uint256 expiresAt
    );

    function getOffer(uint256 offerId) external view returns (
        address creator,
        uint256 minWeight,
        uint256 maxWeight,
        uint256 debtTolerance,
        uint256 price,
        address paymentToken,
        uint256 expiresAt
    );

    function isListingActive(uint256 tokenId) external view returns (bool);
    function isOfferActive(uint256 offerId) external view returns (bool);
    function canOperate(address owner, address operator) external view returns (bool);
}


