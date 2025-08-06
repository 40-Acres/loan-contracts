// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IMarket} from "./interfaces/IMarket.sol";

abstract contract MarketStorage is Ownable2StepUpgradeable {
    /// @custom:storage-location erc7201:storage:MarketStorage
    struct MarketStorageStruct {
        // Market-specific storage
        uint16 marketFeeBps;                                          // fee in basis points, max 1000 (10%)
        address feeRecipient;                                         // fee recipient address
        mapping(uint256 => IMarket.Listing) listings;                        // tokenId => Listing
        mapping(address => mapping(address => bool)) isOperatorFor;   // owner => operator => approved
        mapping(address => bool) allowedPaymentToken;                 // whitelisted payment tokens
        
        // Offer-specific storage
        mapping(uint256 => IMarket.Offer) offers;                     // offerId => Offer
        uint256 _offerCounter;                                         // auto-incrementing offer ID
    }

    // keccak256(abi.encode(uint256(keccak256("erc7201:storage:MarketStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MarketStorageLocation = 0x9a18c57b4cb912563e1d8b7faab1ce6cccddad5bcd773a70cdfb7f991efa2200;

    function _getMarketStorage() internal pure returns (MarketStorageStruct storage $) {
        assembly {
            $.slot := MarketStorageLocation
        }
    }

    // Internal getters and setters for storage
    function _getMarketFeeBps() internal view returns (uint16) {
        MarketStorageStruct storage $ = _getMarketStorage();
        return $.marketFeeBps;
    }

    function _setMarketFeeBps(uint16 feeBps) internal {
        MarketStorageStruct storage $ = _getMarketStorage();
        $.marketFeeBps = feeBps;
    }

    function _getFeeRecipient() internal view returns (address) {
        MarketStorageStruct storage $ = _getMarketStorage();
        return $.feeRecipient;
    }

    function _setFeeRecipient(address recipient) internal {
        MarketStorageStruct storage $ = _getMarketStorage();
        $.feeRecipient = recipient;
    }

    function _getListing(uint256 tokenId) internal view returns (IMarket.Listing storage) {
        MarketStorageStruct storage $ = _getMarketStorage();
        return $.listings[tokenId];
    }

    function _getIsOperatorFor(address owner, address operator) internal view returns (bool) {
        MarketStorageStruct storage $ = _getMarketStorage();
        return $.isOperatorFor[owner][operator];
    }

    function _setIsOperatorFor(address owner, address operator, bool approved) internal {
        MarketStorageStruct storage $ = _getMarketStorage();
        $.isOperatorFor[owner][operator] = approved;
    }

    function _getAllowedPaymentToken(address token) internal view returns (bool) {
        MarketStorageStruct storage $ = _getMarketStorage();
        return $.allowedPaymentToken[token];
    }

    function _setAllowedPaymentToken(address token, bool allowed) internal {
        MarketStorageStruct storage $ = _getMarketStorage();
        $.allowedPaymentToken[token] = allowed;
    }

    function _deleteListing(uint256 tokenId) internal {
        MarketStorageStruct storage $ = _getMarketStorage();
        delete $.listings[tokenId];
    }

    // Offer-specific storage functions
    function _getOffer(uint256 offerId) internal view returns (IMarket.Offer storage) {
        MarketStorageStruct storage $ = _getMarketStorage();
        return $.offers[offerId];
    }

    function _getOfferCounter() internal view returns (uint256) {
        MarketStorageStruct storage $ = _getMarketStorage();
        return $._offerCounter;
    }

    function _incrementOfferCounter() internal returns (uint256) {
        MarketStorageStruct storage $ = _getMarketStorage();
        return ++$._offerCounter;
    }

    function _deleteOffer(uint256 offerId) internal {
        MarketStorageStruct storage $ = _getMarketStorage();
        delete $.offers[offerId];
    }
}