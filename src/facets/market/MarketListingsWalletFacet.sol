// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {MarketLogicLib} from "../../libraries/MarketLogicLib.sol";
import {IMarketListingsWalletFacet} from "../../interfaces/IMarketListingsWalletFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ILoanMinimalOpsWL {
    function getLoanDetails(uint256 tokenId) external view returns (uint256 balance, address borrower);
}

interface IVotingEscrowMinimalOpsWL {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

contract MarketListingsWalletFacet is IMarketListingsWalletFacet {
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

    function makeWalletListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt
    ) external nonReentrant onlyWhenNotPaused {
        require(MarketStorage.configLayout().allowedPaymentToken[paymentToken], "InvalidPaymentToken");
        if (expiresAt != 0) require(expiresAt > block.timestamp, "InvalidExpiration");

        address tokenOwner = IVotingEscrowMinimalOpsWL(MarketStorage.configLayout().votingEscrow).ownerOf(tokenId);
        require(tokenOwner == msg.sender, "Unauthorized");

        // Must not be in Loan custody (borrower must be zero if loan configured)
        address loanAddr = MarketStorage.configLayout().loan;
        if (loanAddr != address(0)) {
            (, address borrower) = ILoanMinimalOpsWL(loanAddr).getLoanDetails(tokenId);
            require(borrower == address(0), "InLoanCustody");
        }

        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        listing.owner = tokenOwner;
        listing.tokenId = tokenId;
        listing.price = price;
        listing.paymentToken = paymentToken;
        listing.hasOutstandingLoan = false;
        listing.expiresAt = expiresAt;

        emit ListingCreated(tokenId, tokenOwner, price, paymentToken, false, expiresAt);
    }

    function updateWalletListing(
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

    function cancelWalletListing(uint256 tokenId) external nonReentrant {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), "ListingNotFound");
        require(MarketLogicLib.canOperate(listing.owner, msg.sender), "Unauthorized");
        delete MarketStorage.orderbookLayout().listings[tokenId];
        emit ListingCancelled(tokenId);
    }

    function takeWalletListing(uint256 tokenId) external payable nonReentrant onlyWhenNotPaused {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), "ListingNotFound");
        require(MarketLogicLib.isListingActive(tokenId), "ListingExpired");
        require(!listing.hasOutstandingLoan, "LoanListing");

        uint256 listingPrice = listing.price;
        IERC20(listing.paymentToken).safeTransferFrom(msg.sender, address(this), listingPrice);

        uint256 fee = (listingPrice * MarketStorage.configLayout().marketFeeBps) / 10000;
        uint256 sellerAmount = listingPrice - fee;
        if (fee > 0) {
            IERC20(listing.paymentToken).safeTransfer(MarketStorage.configLayout().feeRecipient, fee);
        }
        IERC20(listing.paymentToken).safeTransfer(listing.owner, sellerAmount);

        // Transfer veNFT from seller wallet to buyer
        IVotingEscrowMinimalOpsWL(MarketStorage.configLayout().votingEscrow).transferFrom(listing.owner, msg.sender, tokenId);

        delete MarketStorage.orderbookLayout().listings[tokenId];
        emit ListingTaken(tokenId, msg.sender, listingPrice, fee);
    }
}


