// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {MarketLogicLib} from "../../libraries/MarketLogicLib.sol";
import {TransferGuardsLib} from "../../libraries/TransferGuardsLib.sol";
import {Errors} from "../../libraries/Errors.sol";
import {IMarketMatchingFacet} from "../../interfaces/IMarketMatchingFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVexyMarketplace} from "../../interfaces/external/IVexyMarketplace.sol";
import {IVexyAdapterFacet} from "../../interfaces/IVexyAdapterFacet.sol";

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
        if (MarketStorage.managerPauseLayout().marketPaused) revert Errors.Paused();
        _;
    }

    modifier nonReentrant() {
        MarketStorage.MarketPauseLayout storage pause = MarketStorage.managerPauseLayout();
        if (pause.reentrancyStatus == 2) revert Errors.Reentrancy();
        pause.reentrancyStatus = 2;
        _;
        pause.reentrancyStatus = 1;
    }

    function matchOfferWithLoanListing(uint256 offerId, uint256 tokenId) external nonReentrant onlyWhenNotPaused {
        _matchOfferWithLoanListingCommon(offerId, tokenId);
    }

    function matchOfferWithWalletListing(uint256 offerId, uint256 tokenId) external nonReentrant onlyWhenNotPaused {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        if (offer.creator == address(0)) revert Errors.OfferNotFound();
        if (!MarketLogicLib.isOfferActive(offerId)) revert Errors.OfferExpired();

        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        if (listing.owner == address(0)) revert Errors.ListingNotFound();
        if (!MarketLogicLib.isListingActive(tokenId)) revert Errors.ListingExpired();
        if (listing.hasOutstandingLoan) revert Errors.LoanListingNotAllowed();

        _validateOfferCriteriaWalletOrNoLoan(tokenId, offer);

        // Pull funds from offer creator at fill-time
        IERC20(offer.paymentToken).safeTransferFrom(offer.creator, address(this), offer.price);

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

    // Match an internal offer by buying an external Vexy listing and delivering the NFT to the offer creator
    function matchOfferWithVexyListing(
        uint256 offerId,
        address vexy,
        uint256 listingId,
        uint256 maxPrice
    ) external nonReentrant onlyWhenNotPaused {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        if (offer.creator == address(0)) revert Errors.OfferNotFound();
        if (!MarketLogicLib.isOfferActive(offerId)) revert Errors.OfferExpired();

        // Read Vexy listing details
        (
            ,
            ,
            address nftCollection,
            uint256 tokenId,
            address currency,
            ,
            ,
            ,
            ,
            uint64 endTime,
            uint64 soldTime
        ) = IVexyMarketplace(vexy).listings(listingId);

        if (nftCollection != MarketStorage.configLayout().votingEscrow) revert Errors.WrongVotingEscrow();
        if (!(soldTime == 0 && endTime >= block.timestamp)) revert Errors.ListingInactive();

        // Validate offer criteria using wallet/no-loan path (Vexy listings are wallet-held)
        _validateOfferCriteriaWalletOrNoLoan(tokenId, offer);

        // Price and currency checks
        uint256 extPrice = IVexyMarketplace(vexy).listingPrice(listingId);
        if (!(extPrice > 0 && extPrice <= maxPrice)) revert Errors.PriceOutOfBounds();
        if (!MarketStorage.configLayout().allowedPaymentToken[currency]) revert Errors.CurrencyNotAllowed();

        // Compute fee on the external price
        uint256 fee = (extPrice * MarketStorage.configLayout().marketFeeBps) / 10000;

        if (offer.paymentToken == currency) {
            // Pull total cost in exact listing currency
            uint256 totalCost = extPrice + fee;
            if (totalCost > offer.price) revert Errors.OfferTooLow();
            IERC20(currency).safeTransferFrom(offer.creator, address(this), totalCost);
            if (fee > 0) {
                IERC20(currency).safeTransfer(MarketStorage.configLayout().feeRecipient, fee);
            }
            // Buy listing using internal escrow path
            IVexyAdapterFacet(address(this)).buyVexyListing(vexy, listingId, currency, extPrice);
            // Ensure custody is with the diamond before forwarding to user
            TransferGuardsLib.requireCustody(MarketStorage.configLayout().votingEscrow, tokenId, address(this));
        } else {
            // Swap path: pull offer.price in offer.paymentToken, swap to currency, enforce minOut
            IERC20(offer.paymentToken).safeTransferFrom(offer.creator, address(this), offer.price);

            // Perform swap using Swapper-like policy (external to this code; assumed available via loan's swapper config if needed)
            // For now, require direct currency match; swap integration can be added here using router similar to LoanV2
            revert Errors.NotImplemented();
        }

        // Transfer acquired NFT to the offer creator
        IVotingEscrowMinimalOpsMM(MarketStorage.configLayout().votingEscrow).transferFrom(address(this), offer.creator, tokenId);

        // Finalize: delete internal offer record
        delete MarketStorage.orderbookLayout().offers[offerId];
        emit OfferMatched(offerId, tokenId, offer.creator, extPrice, fee);
    }

    function _matchOfferWithLoanListingCommon(uint256 offerId, uint256 tokenId) internal {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        require(offer.creator != address(0), "OfferNotFound");
        require(MarketLogicLib.isOfferActive(offerId), "OfferExpired");

        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), "ListingNotFound");
        require(MarketLogicLib.isListingActive(tokenId), "ListingExpired");

        _validateOfferCriteriaLoan(tokenId, offer);

        // Pull funds from offer creator at fill-time
        IERC20(offer.paymentToken).safeTransferFrom(offer.creator, address(this), offer.price);

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


