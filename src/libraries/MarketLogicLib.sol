// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "./storage/MarketStorage.sol";
import {ILoan} from "../interfaces/ILoan.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {PortfolioFactory} from "../accounts/PortfolioFactory.sol";

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

    /**
     * @notice Check if operator can act on behalf of owner
     * @dev Supports three cases:
     *      1. owner == operator (self)
     *      2. operator is approved via isOperatorFor mapping
     *      3. owner is a portfolio and operator is the portfolio's owner (EOA)
     * @param owner The owner address (could be EOA, portfolio, or other contract)
     * @param operator The address attempting to operate
     * @return True if operator can act on behalf of owner
     */
    function canOperate(address owner, address operator) internal view returns (bool) {
        // Direct match
        if (owner == operator) return true;
        
        // Explicit operator approval
        if (MarketStorage.orderbookLayout().isOperatorFor[owner][operator]) return true;
        
        // Portfolio ownership check: if owner is a portfolio, check if operator is the portfolio's owner
        address portfolioFactory = MarketStorage.configLayout().portfolioFactory;
        if (portfolioFactory != address(0)) {
            PortfolioFactory factory = PortfolioFactory(portfolioFactory);
            if (factory.isPortfolio(owner)) {
                return factory.ownerOf(owner) == operator;
            }
        }
        
        return false;
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
