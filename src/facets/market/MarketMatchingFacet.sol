// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {MarketLogicLib} from "../../libraries/MarketLogicLib.sol";
import {IMarketMatchingFacet} from "../../interfaces/IMarketMatchingFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ILoanMinimalOpsMM {
    function getLoanDetails(uint256 tokenId) external view returns (uint256 balance, address borrower);
    function getLoanWeight(uint256 tokenId) external view returns (uint256 weight);
    function setBorrower(uint256 tokenId, address borrower) external;
}

interface IVotingEscrowMinimalOpsMM {
    struct LockedBalance { int128 amount; uint256 end; bool isPermanent; }
    function locked(uint256 _tokenId) external view returns (LockedBalance memory);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

contract MarketMatchingFacet is IMarketMatchingFacet {
    using SafeERC20 for IERC20;

    modifier onlyWhenNotPaused() {
        require(!MarketStorage.managerPauseLayout().marketPaused, "Paused");
        _;
    }

    modifier nonReentrant() {
        MarketStorage.MarketPauseLayout storage pause = MarketStorage.managerPauseLayout();
        require(pause.reentrancyStatus != 2, "Reentrancy");
        pause.reentrancyStatus = 2;
        _;
        pause.reentrancyStatus = 1;
    }

    function matchOfferWithLoanListing(uint256 offerId, uint256 tokenId) external nonReentrant onlyWhenNotPaused {
        _matchOfferWithLoanListingCommon(offerId, tokenId);
    }

    function matchOfferWithWalletListing(uint256 offerId, uint256 tokenId) external nonReentrant onlyWhenNotPaused {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        require(offer.creator != address(0), "OfferNotFound");
        require(MarketLogicLib.isOfferActive(offerId), "OfferExpired");

        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), "ListingNotFound");
        require(MarketLogicLib.isListingActive(tokenId), "ListingExpired");
        require(!listing.hasOutstandingLoan, "LoanListing");

        _validateOfferCriteriaWalletOrNoLoan(tokenId, offer);

        uint256 fee = (offer.price * MarketStorage.configLayout().marketFeeBps) / 10000;
        uint256 sellerAmount = offer.price - fee;
        if (fee > 0) {
            IERC20(offer.paymentToken).safeTransfer(MarketStorage.configLayout().feeRecipient, fee);
        }
        IERC20(offer.paymentToken).safeTransfer(listing.owner, sellerAmount);

        IVotingEscrowMinimalOpsMM(MarketStorage.configLayout().votingEscrow).transferFrom(listing.owner, offer.creator, tokenId);

        delete MarketStorage.orderbookLayout().listings[tokenId];
        delete MarketStorage.orderbookLayout().offers[offerId];
        emit OfferMatched(offerId, tokenId, offer.creator, offer.price, fee);
    }

    function _matchOfferWithLoanListingCommon(uint256 offerId, uint256 tokenId) internal {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        require(offer.creator != address(0), "OfferNotFound");
        require(MarketLogicLib.isOfferActive(offerId), "OfferExpired");

        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), "ListingNotFound");
        require(MarketLogicLib.isListingActive(tokenId), "ListingExpired");

        _validateOfferCriteriaLoan(tokenId, offer);

        uint256 fee = (offer.price * MarketStorage.configLayout().marketFeeBps) / 10000;
        uint256 sellerAmount = offer.price - fee;
        if (fee > 0) {
            IERC20(offer.paymentToken).safeTransfer(MarketStorage.configLayout().feeRecipient, fee);
        }
        IERC20(offer.paymentToken).safeTransfer(listing.owner, sellerAmount);

        ILoanMinimalOpsMM(MarketStorage.configLayout().loan).setBorrower(tokenId, offer.creator);

        delete MarketStorage.orderbookLayout().listings[tokenId];
        delete MarketStorage.orderbookLayout().offers[offerId];
        emit OfferMatched(offerId, tokenId, offer.creator, offer.price, fee);
    }

    function _validateOfferCriteriaLoan(uint256 tokenId, MarketStorage.Offer storage offer) internal view {
        uint256 weight = ILoanMinimalOpsMM(MarketStorage.configLayout().loan).getLoanWeight(tokenId);
        require(weight >= offer.minWeight, "InsufficientWeight");
        require(weight <= offer.maxWeight, "ExcessiveWeight");
        (uint256 loanBalance,) = ILoanMinimalOpsMM(MarketStorage.configLayout().loan).getLoanDetails(tokenId);
        require(loanBalance <= offer.debtTolerance, "InsufficientDebtTolerance");
        IVotingEscrowMinimalOpsMM.LockedBalance memory lockedBalance = IVotingEscrowMinimalOpsMM(MarketStorage.configLayout().votingEscrow).locked(tokenId);
        require(lockedBalance.end <= offer.maxLockTime, "ExcessiveLockTime");
    }

    function _validateOfferCriteriaWalletOrNoLoan(uint256 tokenId, MarketStorage.Offer storage offer) internal view {
        uint256 weight = MarketLogicLib.getVeNFTWeight(tokenId);
        require(weight >= offer.minWeight, "InsufficientWeight");
        require(weight <= offer.maxWeight, "ExcessiveWeight");
        address loanAddr = MarketStorage.configLayout().loan;
        if (loanAddr != address(0)) {
            (uint256 loanBalance,) = ILoanMinimalOpsMM(loanAddr).getLoanDetails(tokenId);
            require(loanBalance <= offer.debtTolerance, "InsufficientDebtTolerance");
        }
        IVotingEscrowMinimalOpsMM.LockedBalance memory lockedBalance = IVotingEscrowMinimalOpsMM(MarketStorage.configLayout().votingEscrow).locked(tokenId);
        require(lockedBalance.end <= offer.maxLockTime, "ExcessiveLockTime");
    }
}


