// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {MarketLogicLib} from "../../libraries/MarketLogicLib.sol";
import {IMarketListingsWalletFacet} from "../../interfaces/IMarketListingsWalletFacet.sol";
import {Errors} from "../../libraries/Errors.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {FeeLib} from "../../libraries/FeeLib.sol";
import {RouteLib} from "../../libraries/RouteLib.sol";
import {Permit2Lib} from "../../libraries/Permit2Lib.sol";

interface ILoanMinimalOpsWL {
    function getLoanDetails(uint256 tokenId) external view returns (uint256 balance, address borrower);
}

interface IVotingEscrowMinimalOpsWL {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

// Permit2 handled via Permit2Lib

contract MarketListingsWalletFacet is IMarketListingsWalletFacet {
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

    modifier onlyDiamond() {
        if (msg.sender != address(this)) revert Errors.NotAuthorized();
        _;
    }

    function makeWalletListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt
    ) external nonReentrant onlyWhenNotPaused {
        if (!MarketStorage.configLayout().allowedPaymentToken[paymentToken]) revert Errors.CurrencyNotAllowed();
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert Errors.InvalidExpiration();

        address tokenOwner = IVotingEscrowMinimalOpsWL(MarketStorage.configLayout().votingEscrow).ownerOf(tokenId);
        if (tokenOwner != msg.sender) revert Errors.NotAuthorized();

        // Must not be in Loan custody (borrower must be zero if loan configured)
        address loanAddr = MarketStorage.configLayout().loan;
        if (loanAddr != address(0)) {
            (, address borrower) = ILoanMinimalOpsWL(loanAddr).getLoanDetails(tokenId);
            if (borrower != address(0)) revert Errors.InLoanCustody();
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
        if (listing.owner == address(0)) revert Errors.ListingNotFound();
        if (!MarketLogicLib.canOperate(listing.owner, msg.sender)) revert Errors.NotAuthorized();
        if (!MarketStorage.configLayout().allowedPaymentToken[newPaymentToken]) revert Errors.CurrencyNotAllowed();
        if (newExpiresAt != 0 && newExpiresAt <= block.timestamp) revert Errors.InvalidExpiration();

        listing.price = newPrice;
        listing.paymentToken = newPaymentToken;
        listing.expiresAt = newExpiresAt;

        emit ListingUpdated(tokenId, newPrice, newPaymentToken, newExpiresAt);
    }

    function cancelWalletListing(uint256 tokenId) external nonReentrant {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        if (listing.owner == address(0)) revert Errors.ListingNotFound();
        if (!MarketLogicLib.canOperate(listing.owner, msg.sender)) revert Errors.NotAuthorized();
        delete MarketStorage.orderbookLayout().listings[tokenId];
        emit ListingCancelled(tokenId);
    }

    function takeWalletListing(
        uint256 tokenId,
        address inputToken,
        uint256 amountInMax,
        bytes calldata tradeData,
        bytes calldata optionalPermit2
    ) external payable nonReentrant onlyWhenNotPaused {
        _takeWalletListingFor(tokenId, msg.sender, inputToken, amountInMax, tradeData, optionalPermit2);
    }

    function takeWalletListingFor(
        uint256 tokenId,
        address buyer,
        address inputToken,
        uint256 amountInMax,
        bytes calldata tradeData,
        bytes calldata optionalPermit2
    ) external payable nonReentrant onlyWhenNotPaused onlyDiamond {
        _takeWalletListingFor(tokenId, buyer, inputToken, amountInMax, tradeData, optionalPermit2);
    }

    function _takeWalletListingFor(
        uint256 tokenId,
        address buyer,
        address inputToken,
        uint256 amountInMax,
        bytes memory tradeData,
        bytes memory optionalPermit2
    ) internal {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        if (listing.owner == address(0)) revert Errors.ListingNotFound();
        if (!MarketLogicLib.isListingActive(tokenId)) revert Errors.ListingExpired();
        if (listing.hasOutstandingLoan) revert Errors.LoanListingNotAllowed();

        (uint256 price, , address paymentToken) = _quoteWalletListing(tokenId);
        uint256 marketFee = FeeLib.calculateFee(RouteLib.BuyRoute.InternalWallet, price);

        // Optional Permit2 handled via Permit2Lib

        if (inputToken == paymentToken && tradeData.length == 0) {
            // No swap path
            if (inputToken == address(0)) {
                if (msg.value < price) revert Errors.InsufficientETH();
            } else {
                // If optionalPermit2 provided, use Permit2; otherwise fallback to standard transferFrom
                Permit2Lib.permitAndPull(buyer, address(this), inputToken, price, optionalPermit2);
                if (optionalPermit2.length == 0) {
                    IERC20(inputToken).safeTransferFrom(buyer, address(this), price);
                }
            }
        } else if (inputToken != paymentToken && tradeData.length > 0) {
            // Odos swap path
            address odos = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;
            if (inputToken == address(0)) {
                if (msg.value == 0) revert Errors.InsufficientETH();
                (bool success,) = odos.call{value: msg.value}(tradeData);
                require(success);
            } else {
                // Pull max input via Permit2 if provided; otherwise fallback
                Permit2Lib.permitAndPull(buyer, address(this), inputToken, amountInMax, optionalPermit2);
                if (optionalPermit2.length == 0) {
                    IERC20(inputToken).safeTransferFrom(buyer, address(this), amountInMax);
                }
                IERC20(inputToken).approve(odos, amountInMax);
                (bool success2,) = odos.call{value: 0}(tradeData);
                require(success2);
                IERC20(inputToken).approve(odos, 0);
            }
            // Must have at least price of payment token
            if (IERC20(paymentToken).balanceOf(address(this)) < price) revert Errors.Slippage();
        } else {
            revert Errors.InvalidRoute();
        }

        // Settle
        if (marketFee > 0) IERC20(paymentToken).safeTransfer(FeeLib.feeRecipient(), marketFee);
        IVotingEscrowMinimalOpsWL(MarketStorage.configLayout().votingEscrow).transferFrom(listing.owner, buyer, tokenId);
        IERC20(paymentToken).safeTransfer(listing.owner, price - marketFee);
        delete MarketStorage.orderbookLayout().listings[tokenId];
        emit ListingTaken(tokenId, buyer, price, marketFee);
    }

    // Removed separate Permit2 function; handled within unified takeWalletListing

    // Removed legacy helper

    function quoteWalletListing(
        uint256 tokenId
    ) external view returns (
        uint256 listingPriceInPaymentToken,
        uint256 protocolFeeInPaymentToken,
        address paymentToken
    ) {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        if (listing.owner == address(0)) revert Errors.ListingNotFound();
        if (!MarketLogicLib.isListingActive(tokenId)) revert Errors.ListingExpired();
        (uint256 a, uint256 b, address d) = _quoteWalletListing(tokenId);
        return (a, b, d);
    }

    function _quoteWalletListing(
        uint256 tokenId
    ) internal view returns (
        uint256 listingPriceInPaymentToken,
        uint256 protocolFeeInPaymentToken,
        address paymentToken
    ) {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        // listing validity is checked in the public entry path to avoid duplicate gas here
        
        listingPriceInPaymentToken = listing.price;
        paymentToken = listing.paymentToken;
        protocolFeeInPaymentToken = FeeLib.calculateFee(RouteLib.BuyRoute.InternalWallet, listingPriceInPaymentToken);
        return (listingPriceInPaymentToken, protocolFeeInPaymentToken, paymentToken);
    }

    function _takeWalletListing(uint256 tokenId, address inputToken) internal {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        
        // Listing validity has already been checked in public entry
        (uint256 price, uint256 marketFee, address paymentToken) = _quoteWalletListing(tokenId);
        if (inputToken == paymentToken) {
            // Direct payment - no swap needed
            IERC20(inputToken).safeTransferFrom(msg.sender, address(this), price);
        } else {
            revert Errors.InputTokenNotAllowed();
        }

        // At this point we have the correct payment token and enough to pay for the listing

        // Seller pays fee: distribute price - fee to seller, fee to recipient
        if (marketFee > 0) {
            IERC20(paymentToken).safeTransfer(FeeLib.feeRecipient(), marketFee);
        }

        // Transfer veNFT from seller wallet to buyer
        IVotingEscrowMinimalOpsWL(MarketStorage.configLayout().votingEscrow).transferFrom(listing.owner, msg.sender, tokenId);

        // Send net proceeds to seller (price - fee)
        IERC20(paymentToken).safeTransfer(listing.owner, price - marketFee);

        // Delete listing
        delete MarketStorage.orderbookLayout().listings[tokenId];

        emit ListingTaken(tokenId, msg.sender, price, marketFee);
    }
}


