// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "./storage/MarketStorage.sol";
import {ILoan} from "../interfaces/ILoan.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";

library MarketLogicLib {
    function getTokenOwnerOrBorrower(uint256 tokenId) internal view returns (address) {
        (, address borrower) = ILoan(MarketStorage.configLayout().loan).getLoanDetails(tokenId);
        if (borrower != address(0)) {
            return borrower;
        }
        return IVotingEscrow(MarketStorage.configLayout().votingEscrow).ownerOf(tokenId);
    }

    function isListingActive(uint256 tokenId) internal view returns (bool) {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        return listing.owner != address(0) && (listing.expiresAt == 0 || block.timestamp < listing.expiresAt);
    }

    function isOfferActive(uint256 offerId) internal view returns (bool) {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        return offer.creator != address(0) && (offer.expiresAt == 0 || block.timestamp < offer.expiresAt);
    }

    function canOperate(address owner, address operator) internal view returns (bool) {
        return owner == operator || MarketStorage.orderbookLayout().isOperatorFor[owner][operator];
    }

    function getVeNFTWeight(uint256 tokenId) internal view returns (uint256) {
        IVotingEscrow.LockedBalance memory lockedBalance = IVotingEscrow(MarketStorage.configLayout().votingEscrow).locked(tokenId);
        if (!lockedBalance.isPermanent && lockedBalance.end < block.timestamp) {
            return 0;
        }
        require(lockedBalance.amount >= 0);
        return uint256(uint128(lockedBalance.amount));
    }
}


