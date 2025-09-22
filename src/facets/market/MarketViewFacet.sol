// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {IMarketViewFacet} from "../../interfaces/IMarketViewFacet.sol";
import {MarketLogicLib} from "../../libraries/MarketLogicLib.sol";
import {RouteLib} from "../../libraries/RouteLib.sol";
import {ILoan} from "../../interfaces/ILoan.sol";
import {IVotingEscrow} from "../../interfaces/IVotingEscrow.sol";
contract MarketViewFacet is IMarketViewFacet {
    // ============ PUBLIC STATE GETTERS ==========
    function loan() external view returns (address) {
        return MarketStorage.configLayout().loan;
    }

    function marketFeeBps(RouteLib.BuyRoute routeType) external view returns (uint16) {
        return MarketStorage.configLayout().feeBps[routeType];
    }

    function feeRecipient() external view returns (address) {
        return MarketStorage.configLayout().feeRecipient;
    }

    function loanAsset() external view returns (address) {
        return MarketStorage.configLayout().loanAsset;
    }

    function isOperatorFor(address owner, address operator) external view returns (bool) {
        return MarketStorage.orderbookLayout().isOperatorFor[owner][operator];
    }

    function allowedPaymentToken(address token) external view returns (bool) {
        return MarketStorage.configLayout().allowedPaymentToken[token];
    }

    // ============ VIEW FUNCTIONS ==========
    function getListing(uint256 tokenId) external view returns (
        address owner,
        uint256 price,
        address paymentToken,
        bool hasOutstandingLoan,
        uint256 expiresAt
    ) {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        return (listing.owner, listing.price, listing.paymentToken, listing.hasOutstandingLoan, listing.expiresAt);
    }

    function getOffer(uint256 offerId) external view returns (
        address creator,
        uint256 minWeight,
        uint256 debtTolerance,
        uint256 price,
        address paymentToken,
        uint256 expiresAt
    ) {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        return (
            offer.creator,
            offer.minWeight,
            offer.debtTolerance,
            offer.price,
            offer.paymentToken,
            offer.expiresAt
        );
    }

    function isListingActive(uint256 tokenId) external view returns (bool) {
        return MarketLogicLib.isListingActive(tokenId);
    }

    function isOfferActive(uint256 offerId) external view returns (bool) {
        return _isOfferActive(offerId);
    }

    function canOperate(address owner, address operator) external view returns (bool) {
        return _canOperate(owner, operator);
    }

    // ============ LBO FEE CONFIG ==========
    function getLBOLenderFeeBps() external view returns (uint256) {
        return MarketStorage.configLayout().lboLenderFeeBps;
    }

    function getLBOProtocolFeeBps() external view returns (uint256) {
        return MarketStorage.configLayout().lboProtocolFeeBps;
    }

    // ============ INTERNAL VIEW HELPERS ==========
    function _getTokenOwnerOrBorrower(uint256 tokenId) internal view returns (address) {
        (, address borrower) = ILoan(MarketStorage.configLayout().loan).getLoanDetails(tokenId);
        if (borrower != address(0)) {
            return borrower;
        }
        return IVotingEscrow(MarketStorage.configLayout().votingEscrow).ownerOf(tokenId);
    }

    function _isListingActive(uint256 tokenId) internal view returns (bool) {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        return listing.owner != address(0) && (listing.expiresAt == 0 || block.timestamp < listing.expiresAt);
    }

    function _isOfferActive(uint256 offerId) internal view returns (bool) {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        return offer.creator != address(0) && (offer.expiresAt == 0 || block.timestamp < offer.expiresAt);
    }

    function _canOperate(address owner, address operator) internal view returns (bool) {
        return owner == operator || MarketStorage.orderbookLayout().isOperatorFor[owner][operator];
    }
}

