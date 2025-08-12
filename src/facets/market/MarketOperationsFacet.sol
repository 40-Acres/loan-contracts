// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {LibDiamond} from "../../libraries/LibDiamond.sol";
import {IMarketOperationsFacet} from "../../interfaces/IMarketOperationsFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ILoanMinimalOps {
    function getLoanDetails(uint256 tokenId) external view returns (uint256 balance, address borrower);
    function getLoanWeight(uint256 tokenId) external view returns (uint256 weight);
    function pay(uint256 tokenId, uint256 amount) external;
    function setBorrower(uint256 tokenId, address borrower) external;
}

interface IVotingEscrowMinimalOps {
    function ownerOf(uint256 tokenId) external view returns (address);
    struct LockedBalance { int128 amount; uint256 end; bool isPermanent; }
    function locked(uint256 _tokenId) external view returns (LockedBalance memory);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

contract MarketOperationsFacet is IMarketOperationsFacet {
    using SafeERC20 for IERC20;

    // ============ CONSTANTS ==========
    uint16 private constant MAX_FEE_BPS = 1000; // 10%

    // ============ MODIFIERS ==========
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

    // ============ LISTINGS ==========
    function makeListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt
    ) external nonReentrant onlyWhenNotPaused {
        _makeListing(tokenId, price, paymentToken, expiresAt, msg.sender);
    }

    function updateListing(
        uint256 tokenId,
        uint256 newPrice,
        address newPaymentToken,
        uint256 newExpiresAt
    ) external nonReentrant onlyWhenNotPaused {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), "ListingNotFound");
        require(_canOperate(listing.owner, msg.sender), "Unauthorized");
        require(MarketStorage.configLayout().allowedPaymentToken[newPaymentToken], "InvalidPaymentToken");
        if (newExpiresAt != 0) require(newExpiresAt > block.timestamp, "InvalidExpiration");

        listing.price = newPrice;
        listing.paymentToken = newPaymentToken;
        listing.expiresAt = newExpiresAt;

        emit ListingUpdated(tokenId, newPrice, newPaymentToken, newExpiresAt);
    }

    function cancelListing(uint256 tokenId) external nonReentrant {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), "ListingNotFound");
        require(_canOperate(listing.owner, msg.sender), "Unauthorized");
        delete MarketStorage.orderbookLayout().listings[tokenId];
        emit ListingCancelled(tokenId);
    }

    function takeListing(uint256 tokenId) external payable nonReentrant onlyWhenNotPaused {
        _takeListing(tokenId, msg.sender);
    }

    // ============ OFFERS ==========
    function createOffer(
        uint256 minWeight,
        uint256 maxWeight,
        uint256 debtTolerance,
        uint256 price,
        address paymentToken,
        uint256 maxLockTime,
        uint256 expiresAt
    ) external payable nonReentrant onlyWhenNotPaused {
        require(MarketStorage.configLayout().allowedPaymentToken[paymentToken], "InvalidPaymentToken");
        require(minWeight <= maxWeight, "InvalidWeightRange");
        if (expiresAt != 0) require(expiresAt > block.timestamp, "InvalidExpiration");

        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), price);

        uint256 offerId = ++MarketStorage.orderbookLayout()._offerCounter;
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        offer.creator = msg.sender;
        offer.minWeight = minWeight;
        offer.maxWeight = maxWeight;
        offer.debtTolerance = debtTolerance;
        offer.price = price;
        offer.paymentToken = paymentToken;
        offer.maxLockTime = maxLockTime;
        offer.expiresAt = expiresAt;
        offer.offerId = offerId;

        emit OfferCreated(offerId, msg.sender, minWeight, maxWeight, debtTolerance, price, paymentToken, maxLockTime, expiresAt);
    }

    function updateOffer(
        uint256 offerId,
        uint256 newMinWeight,
        uint256 newMaxWeight,
        uint256 newDebtTolerance,
        uint256 newPrice,
        address newPaymentToken,
        uint256 newMaxLockTime,
        uint256 newExpiresAt
    ) external nonReentrant onlyWhenNotPaused {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        require(offer.creator != address(0), "OfferNotFound");
        require(offer.creator == msg.sender, "Unauthorized");
        require(MarketStorage.configLayout().allowedPaymentToken[newPaymentToken], "InvalidPaymentToken");
        require(newMinWeight <= newMaxWeight, "InvalidWeightRange");
        if (newExpiresAt != 0) require(newExpiresAt > block.timestamp, "InvalidExpiration");

        if (newPrice != offer.price) {
            if (newPrice > offer.price) {
                IERC20(newPaymentToken).safeTransferFrom(msg.sender, address(this), newPrice - offer.price);
            } else {
                IERC20(offer.paymentToken).safeTransfer(msg.sender, offer.price - newPrice);
            }
        }

        offer.minWeight = newMinWeight;
        offer.maxWeight = newMaxWeight;
        offer.debtTolerance = newDebtTolerance;
        offer.price = newPrice;
        offer.paymentToken = newPaymentToken;
        offer.maxLockTime = newMaxLockTime;
        offer.expiresAt = newExpiresAt;

        emit OfferUpdated(offerId, newMinWeight, newMaxWeight, newDebtTolerance, newPrice, newPaymentToken, newMaxLockTime, newExpiresAt);
    }

    function cancelOffer(uint256 offerId) external nonReentrant {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        require(offer.creator != address(0), "OfferNotFound");
        require(offer.creator == msg.sender, "Unauthorized");
        IERC20(offer.paymentToken).safeTransfer(msg.sender, offer.price);
        delete MarketStorage.orderbookLayout().offers[offerId];
        emit OfferCancelled(offerId);
    }

    function acceptOffer(uint256 tokenId, uint256 offerId, bool isInLoanV2) external nonReentrant onlyWhenNotPaused {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        require(offer.creator != address(0), "OfferNotFound");
        require(_isOfferActive(offerId), "OfferExpired");

        address tokenOwner = _getTokenOwnerOrBorrower(tokenId);
        require(_canOperate(tokenOwner, msg.sender), "Unauthorized");

        _validateOfferCriteria(tokenId, offer, isInLoanV2);

        uint256 fee = (offer.price * MarketStorage.configLayout().marketFeeBps) / 10000;
        uint256 sellerAmount = offer.price - fee;
        if (fee > 0) {
            IERC20(offer.paymentToken).safeTransfer(MarketStorage.configLayout().feeRecipient, fee);
        }
        IERC20(offer.paymentToken).safeTransfer(msg.sender, sellerAmount);

        if (isInLoanV2) {
            ILoanMinimalOps(MarketStorage.configLayout().loan).setBorrower(tokenId, offer.creator);
        } else {
            IVotingEscrowMinimalOps(MarketStorage.configLayout().votingEscrow).transferFrom(msg.sender, offer.creator, tokenId);
        }

        delete MarketStorage.orderbookLayout().offers[offerId];
        emit OfferAccepted(offerId, tokenId, msg.sender, offer.price, fee);
    }

    function matchOfferWithListing(uint256 offerId, uint256 tokenId) external nonReentrant onlyWhenNotPaused {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        require(offer.creator != address(0), "OfferNotFound");
        require(_isOfferActive(offerId), "OfferExpired");

        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), "ListingNotFound");
        require(_isListingActive(tokenId), "ListingExpired");

        _validateOfferCriteria(tokenId, offer);

        uint256 fee = (offer.price * MarketStorage.configLayout().marketFeeBps) / 10000;
        uint256 sellerAmount = offer.price - fee;
        if (fee > 0) {
            IERC20(offer.paymentToken).safeTransfer(MarketStorage.configLayout().feeRecipient, fee);
        }
        IERC20(offer.paymentToken).safeTransfer(listing.owner, sellerAmount);

        ILoanMinimalOps(MarketStorage.configLayout().loan).setBorrower(tokenId, offer.creator);

        delete MarketStorage.orderbookLayout().listings[tokenId];
        delete MarketStorage.orderbookLayout().offers[offerId];
        emit OfferMatched(offerId, tokenId, offer.creator, offer.price, fee);
    }

    function setOperatorApproval(address operator, bool approved) external {
        MarketStorage.orderbookLayout().isOperatorFor[msg.sender][operator] = approved;
        emit OperatorApproved(msg.sender, operator, approved);
    }

    // ============ INTERNALS ==========
    function _makeListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt,
        address caller
    ) internal {
        require(MarketStorage.configLayout().allowedPaymentToken[paymentToken], "InvalidPaymentToken");
        if (expiresAt != 0) require(expiresAt > block.timestamp, "InvalidExpiration");

        address tokenOwner = _getTokenOwnerOrBorrower(tokenId);
        require(_canOperate(tokenOwner, caller), "Unauthorized");

        if (IVotingEscrowMinimalOps(MarketStorage.configLayout().votingEscrow).ownerOf(tokenId) == caller) {
            revert("veNFT must be deposited into LoanV2 before listing. Call loan.requestLoan() first.");
        }

        (uint256 balance,) = ILoanMinimalOps(MarketStorage.configLayout().loan).getLoanDetails(tokenId);
        bool hasOutstandingLoan = balance > 0;

        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        listing.owner = tokenOwner;
        listing.tokenId = tokenId;
        listing.price = price;
        listing.paymentToken = paymentToken;
        listing.hasOutstandingLoan = hasOutstandingLoan;
        listing.expiresAt = expiresAt;

        emit ListingCreated(tokenId, tokenOwner, price, paymentToken, hasOutstandingLoan, expiresAt);
    }

    function _takeListing(uint256 tokenId, address buyer) internal {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), "ListingNotFound");
        require(_isListingActive(tokenId), "ListingExpired");

        (uint256 total, uint256 listingPrice, uint256 loanBalance,) = _getTotalCost(tokenId);
        IERC20(listing.paymentToken).safeTransferFrom(buyer, address(this), total);

        if (listing.hasOutstandingLoan && loanBalance > 0) {
            IERC20(listing.paymentToken).approve(MarketStorage.configLayout().loan, loanBalance);
            ILoanMinimalOps(MarketStorage.configLayout().loan).pay(tokenId, loanBalance);
        }

        uint256 fee = (listingPrice * MarketStorage.configLayout().marketFeeBps) / 10000;
        uint256 sellerAmount = listingPrice - fee;
        if (fee > 0) {
            IERC20(listing.paymentToken).safeTransfer(MarketStorage.configLayout().feeRecipient, fee);
        }
        IERC20(listing.paymentToken).safeTransfer(listing.owner, sellerAmount);

        ILoanMinimalOps(MarketStorage.configLayout().loan).setBorrower(tokenId, buyer);

        delete MarketStorage.orderbookLayout().listings[tokenId];
        emit ListingTaken(tokenId, buyer, listingPrice, fee);
    }

    function _getVeNFTWeight(uint256 tokenId) internal view returns (uint256) {
        IVotingEscrowMinimalOps.LockedBalance memory lockedBalance = IVotingEscrowMinimalOps(MarketStorage.configLayout().votingEscrow).locked(tokenId);
        if (!lockedBalance.isPermanent && lockedBalance.end < block.timestamp) {
            return 0;
        }
        require(lockedBalance.amount >= 0);
        return uint256(uint128(lockedBalance.amount));
    }

    function _validateOfferCriteria(uint256 tokenId, MarketStorage.Offer storage offer) internal view {
        uint256 weight = _getVeNFTWeight(tokenId);
        require(weight >= offer.minWeight, "InsufficientWeight");
        require(weight <= offer.maxWeight, "ExcessiveWeight");
        (uint256 loanBalance,) = ILoanMinimalOps(MarketStorage.configLayout().loan).getLoanDetails(tokenId);
        require(loanBalance <= offer.debtTolerance, "InsufficientDebtTolerance");
        IVotingEscrowMinimalOps.LockedBalance memory lockedBalance = IVotingEscrowMinimalOps(MarketStorage.configLayout().votingEscrow).locked(tokenId);
        require(lockedBalance.end <= offer.maxLockTime, "ExcessiveLockTime");
    }

    function _validateOfferCriteria(uint256 tokenId, MarketStorage.Offer storage offer, bool isInLoanV2) internal view {
        uint256 weight = isInLoanV2
            ? ILoanMinimalOps(MarketStorage.configLayout().loan).getLoanWeight(tokenId)
            : _getVeNFTWeight(tokenId);
        require(weight >= offer.minWeight, "InsufficientWeight");
        require(weight <= offer.maxWeight, "ExcessiveWeight");
        (uint256 loanBalance,) = ILoanMinimalOps(MarketStorage.configLayout().loan).getLoanDetails(tokenId);
        require(loanBalance <= offer.debtTolerance, "InsufficientDebtTolerance");
        IVotingEscrowMinimalOps.LockedBalance memory lockedBalance = IVotingEscrowMinimalOps(MarketStorage.configLayout().votingEscrow).locked(tokenId);
        require(lockedBalance.end <= offer.maxLockTime, "ExcessiveLockTime");
    }

    function _getTokenOwnerOrBorrower(uint256 tokenId) internal view returns (address) {
        (, address borrower) = ILoanMinimalOps(MarketStorage.configLayout().loan).getLoanDetails(tokenId);
        if (borrower != address(0)) {
            return borrower;
        }
        return IVotingEscrowMinimalOps(MarketStorage.configLayout().votingEscrow).ownerOf(tokenId);
    }

    function _isListingActive(uint256 tokenId) internal view returns (bool) {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        return listing.owner != address(0) && (listing.expiresAt == 0 || block.timestamp < listing.expiresAt);
    }

    function _isOfferActive(uint256 offerId) internal view returns (bool) {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        return offer.creator != address(0) && (offer.expiresAt == 0 || block.timestamp < offer.expiresAt);
    }

    function _getTotalCost(uint256 tokenId) internal view returns (
        uint256 total,
        uint256 listingPrice,
        uint256 loanBalance,
        address paymentToken
    ) {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), "ListingNotFound");
        listingPrice = listing.price;
        paymentToken = listing.paymentToken;
        if (listing.hasOutstandingLoan) {
            (loanBalance,) = ILoanMinimalOps(MarketStorage.configLayout().loan).getLoanDetails(tokenId);
        }
        total = listingPrice + loanBalance;
    }

    function _canOperate(address owner, address operator) internal view returns (bool) {
        return owner == operator || MarketStorage.orderbookLayout().isOperatorFor[owner][operator];
    }
}

