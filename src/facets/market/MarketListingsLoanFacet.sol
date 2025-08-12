// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {MarketLogicLib} from "../../libraries/MarketLogicLib.sol";
import {IMarketListingsLoanFacet} from "../../interfaces/IMarketListingsLoanFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ILoanMinimalOpsLL {
    function getLoanDetails(uint256 tokenId) external view returns (uint256 balance, address borrower);
    function pay(uint256 tokenId, uint256 amount) external;
    function setBorrower(uint256 tokenId, address borrower) external;
}

interface IVotingEscrowMinimalOpsLL {
    function ownerOf(uint256 tokenId) external view returns (address);
}

contract MarketListingsLoanFacet is IMarketListingsLoanFacet {
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

    function makeLoanListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt
    ) external nonReentrant onlyWhenNotPaused {
        require(MarketStorage.configLayout().allowedPaymentToken[paymentToken], "InvalidPaymentToken");
        if (expiresAt != 0) require(expiresAt > block.timestamp, "InvalidExpiration");

        address tokenOwner = MarketLogicLib.getTokenOwnerOrBorrower(tokenId);
        require(MarketLogicLib.canOperate(tokenOwner, msg.sender), "Unauthorized");

        // Ensure token is in Loan custody (not wallet): ownerOf(tokenId) != msg.sender
        require(IVotingEscrowMinimalOpsLL(MarketStorage.configLayout().votingEscrow).ownerOf(tokenId) != msg.sender, "WalletHeld");

        (uint256 balance,) = ILoanMinimalOpsLL(MarketStorage.configLayout().loan).getLoanDetails(tokenId);
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

    function updateLoanListing(
        uint256 tokenId,
        uint256 newPrice,
        address newPaymentToken,
        uint256 newExpiresAt
    ) external nonReentrant onlyWhenNotPaused {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), "ListingNotFound");
        require(MarketLogicLib.canOperate(listing.owner, msg.sender), "Unauthorized");
        require(MarketStorage.configLayout().allowedPaymentToken[newPaymentToken], "InvalidPaymentToken");
        if (newExpiresAt != 0) require(newExpiresAt > block.timestamp, "InvalidExpiration");

        listing.price = newPrice;
        listing.paymentToken = newPaymentToken;
        listing.expiresAt = newExpiresAt;

        emit ListingUpdated(tokenId, newPrice, newPaymentToken, newExpiresAt);
    }

    function cancelLoanListing(uint256 tokenId) external nonReentrant {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), "ListingNotFound");
        require(MarketLogicLib.canOperate(listing.owner, msg.sender), "Unauthorized");
        delete MarketStorage.orderbookLayout().listings[tokenId];
        emit ListingCancelled(tokenId);
    }

    function takeLoanListing(uint256 tokenId) external payable nonReentrant onlyWhenNotPaused {
        _takeLoanListing(tokenId, msg.sender);
    }

    function takeLoanListingWithDebt(uint256 tokenId, uint256 debtTolerance) external payable nonReentrant onlyWhenNotPaused {
        _takeLoanListingWithDebt(tokenId, msg.sender, debtTolerance);
    }

    function _takeLoanListing(uint256 tokenId, address buyer) internal {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), "ListingNotFound");
        require(MarketLogicLib.isListingActive(tokenId), "ListingExpired");

        (uint256 total, uint256 listingPrice, uint256 loanBalance,) = MarketLogicLib.getTotalCost(tokenId);
        if (loanBalance > 0) {
            require(listing.paymentToken == MarketStorage.configLayout().loanAsset, "WrongPaymentAsset");
            require(MarketStorage.configLayout().loan != address(0), "LoanNotConfigured");
        }
        IERC20(listing.paymentToken).safeTransferFrom(buyer, address(this), total);

        if (listing.hasOutstandingLoan && loanBalance > 0) {
            IERC20(listing.paymentToken).approve(MarketStorage.configLayout().loan, loanBalance);
            ILoanMinimalOpsLL(MarketStorage.configLayout().loan).pay(tokenId, loanBalance);
        }

        uint256 fee = (listingPrice * MarketStorage.configLayout().marketFeeBps) / 10000;
        uint256 sellerAmount = listingPrice - fee;
        if (fee > 0) {
            IERC20(listing.paymentToken).safeTransfer(MarketStorage.configLayout().feeRecipient, fee);
        }
        IERC20(listing.paymentToken).safeTransfer(listing.owner, sellerAmount);

        ILoanMinimalOpsLL(MarketStorage.configLayout().loan).setBorrower(tokenId, buyer);

        delete MarketStorage.orderbookLayout().listings[tokenId];
        emit ListingTaken(tokenId, buyer, listingPrice, fee);
    }

    function _takeLoanListingWithDebt(uint256 tokenId, address buyer, uint256 debtTolerance) internal {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), "ListingNotFound");
        require(MarketLogicLib.isListingActive(tokenId), "ListingExpired");

        (uint256 loanBalance,) = ILoanMinimalOpsLL(MarketStorage.configLayout().loan).getLoanDetails(tokenId);
        uint256 payoffAmount = 0;
        if (listing.hasOutstandingLoan && loanBalance > debtTolerance) {
            payoffAmount = loanBalance - debtTolerance;
        }

        uint256 listingPrice = listing.price;
        uint256 total = listingPrice + payoffAmount;
        if (payoffAmount > 0) {
            require(listing.paymentToken == MarketStorage.configLayout().loanAsset, "WrongPaymentAsset");
            require(MarketStorage.configLayout().loan != address(0), "LoanNotConfigured");
        }
        IERC20(listing.paymentToken).safeTransferFrom(buyer, address(this), total);

        if (payoffAmount > 0) {
            IERC20(listing.paymentToken).approve(MarketStorage.configLayout().loan, payoffAmount);
            ILoanMinimalOpsLL(MarketStorage.configLayout().loan).pay(tokenId, payoffAmount);
        }

        uint256 fee = (listingPrice * MarketStorage.configLayout().marketFeeBps) / 10000;
        uint256 sellerAmount = listingPrice - fee;
        if (fee > 0) {
            IERC20(listing.paymentToken).safeTransfer(MarketStorage.configLayout().feeRecipient, fee);
        }
        IERC20(listing.paymentToken).safeTransfer(listing.owner, sellerAmount);

        ILoanMinimalOpsLL(MarketStorage.configLayout().loan).setBorrower(tokenId, buyer);

        delete MarketStorage.orderbookLayout().listings[tokenId];
        emit ListingTaken(tokenId, buyer, listingPrice, fee);
    }
}


