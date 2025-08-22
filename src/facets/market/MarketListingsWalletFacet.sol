// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {MarketLogicLib} from "../../libraries/MarketLogicLib.sol";
import {IMarketListingsWalletFacet} from "../../interfaces/IMarketListingsWalletFacet.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {SwapRouterLib} from "../../libraries/SwapRouterLib.sol";

interface ILoanMinimalOpsWL {
    function getLoanDetails(uint256 tokenId) external view returns (uint256 balance, address borrower);
}

interface IVotingEscrowMinimalOpsWL {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

interface IPermit2Minimal {
    struct TokenPermissions { address token; uint256 amount; }
    struct PermitSingle { TokenPermissions permitted; uint256 nonce; uint256 deadline; address spender; }
    function permit(address owner, PermitSingle calldata permitSingle, bytes calldata signature) external;
    function transferFrom(address from, address to, uint160 amount, address token) external;
}

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

    function takeWalletListing(uint256 tokenId, address inputToken) external payable nonReentrant onlyWhenNotPaused {
        // Single validation pass
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        if (listing.owner == address(0)) revert Errors.ListingNotFound();
        if (!MarketLogicLib.isListingActive(tokenId)) revert Errors.ListingExpired();
        if (listing.hasOutstandingLoan) revert Errors.LoanListingNotAllowed();
        if (inputToken == address(0)) {
            if (msg.value == 0) revert Errors.InsufficientETH();
        } else {
            if (!MarketStorage.configLayout().allowedPaymentToken[inputToken]) revert Errors.InputTokenNotAllowed();
            if (msg.value != 0) revert Errors.NoETHForTokenPayment();
        }

        _takeWalletListing(tokenId, inputToken);
    }

    function takeWalletListingWithPermit(
        uint256 tokenId,
        address inputToken,
        IPermit2Minimal.PermitSingle calldata permitSingle,
        bytes calldata signature
    ) external payable nonReentrant onlyWhenNotPaused {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        if (listing.owner == address(0)) revert Errors.ListingNotFound();
        if (!MarketLogicLib.isListingActive(tokenId)) revert Errors.ListingExpired();
        if (listing.hasOutstandingLoan) revert Errors.LoanListingNotAllowed();

        if (inputToken == address(0)) {
            // ETH path ignores permit; delegate to normal take
            _takeWalletListing(tokenId, inputToken);
            return;
        }

        if (!MarketStorage.configLayout().allowedPaymentToken[inputToken]) revert Errors.InputTokenNotAllowed();
        if (msg.value != 0) revert Errors.NoETHForTokenPayment();

        (uint256 price, uint256 marketFee, uint256 total, address paymentToken) = _quoteWalletListing(tokenId, inputToken);

        address router = MarketStorage.configLayout().swapRouter;
        address factory = MarketStorage.configLayout().swapFactory;
        address[] memory supportedTokens = MarketStorage.configLayout().supportedSwapTokens;
        if (router == address(0) || factory == address(0)) revert Errors.SwapNotConfigured();

        // Call Permit2 to set allowance and then transfer input tokens to this contract
        address permit2 = MarketStorage.configLayout().permit2;
        require(permit2 != address(0), "Permit2NotSet");
        IPermit2Minimal(permit2).permit(msg.sender, permitSingle, signature);
        IPermit2Minimal(permit2).transferFrom(msg.sender, address(this), uint160(total), inputToken);

        if (inputToken != paymentToken) {
            // Swap from this contract balance to payment token
            SwapRouterLib.swapExactInBestRoute(
                inputToken,
                paymentToken,
                total,
                price,
                supportedTokens,
                factory,
                router,
                address(this),
                block.timestamp + 300
            );
        }

        // Settle: fee then seller
        if (marketFee > 0) {
            IERC20(paymentToken).safeTransfer(MarketStorage.configLayout().feeRecipient, marketFee);
        }
        IVotingEscrowMinimalOpsWL(MarketStorage.configLayout().votingEscrow).transferFrom(listing.owner, msg.sender, tokenId);
        IERC20(paymentToken).safeTransfer(listing.owner, price - marketFee);
        delete MarketStorage.orderbookLayout().listings[tokenId];
        emit ListingTaken(tokenId, msg.sender, price, marketFee);
    }

    function quoteWalletListing(
        uint256 tokenId,
        address inputToken
    ) external view returns (
        uint256 listingPriceInPaymentToken,
        uint256 protocolFeeInPaymentToken,
        uint256 requiredInputTokenAmount,
        address paymentToken
    ) {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        if (listing.owner == address(0)) revert Errors.ListingNotFound();
        if (!MarketLogicLib.isListingActive(tokenId)) revert Errors.ListingExpired();
        require(inputToken == address(0) || MarketStorage.configLayout().allowedPaymentToken[inputToken], "InputTokenNotAllowed");
        (uint256 a, uint256 b, uint256 c, address d) = _quoteWalletListing(tokenId, inputToken);
        return (a, b, c, d);
    }

    function _quoteWalletListing(
        uint256 tokenId,
        address inputToken
    ) internal view returns (
        uint256 listingPriceInPaymentToken,
        uint256 protocolFeeInPaymentToken,
        uint256 requiredInputTokenAmount,
        address paymentToken
    ) {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        // listing validity is checked in the public entry path to avoid duplicate gas here
        
        listingPriceInPaymentToken = listing.price;
        paymentToken = listing.paymentToken;
        protocolFeeInPaymentToken = _calculateMarketFee(listingPriceInPaymentToken);
        
        // If input token is the same as payment token, no swap needed
        if (inputToken == paymentToken) {
            return (listingPriceInPaymentToken, protocolFeeInPaymentToken, listingPriceInPaymentToken, paymentToken);
        }

        // Calculate how much input is needed to get exactly `price` in payment token (seller pays fee)
        if (inputToken == address(0)) {
            requiredInputTokenAmount = SwapRouterLib.getAmountInETHForExactOutFromConfig(paymentToken, listingPriceInPaymentToken);
        } else {
            requiredInputTokenAmount = SwapRouterLib.getAmountInForExactOutFromConfig(inputToken, paymentToken, listingPriceInPaymentToken);
        }
        return (listingPriceInPaymentToken, protocolFeeInPaymentToken, requiredInputTokenAmount, paymentToken);
    }

    function _takeWalletListing(uint256 tokenId, address inputToken) internal {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        
        // Listing validity has already been checked in public entry
        (uint256 price, uint256 marketFee, uint256 total, address paymentToken) = _quoteWalletListing(tokenId, inputToken);
        if (inputToken == paymentToken) {
            // Direct payment - no swap needed
        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), total);
        } else if (inputToken == address(0)) {
            // ETH → payment token
            if (msg.value < total) revert Errors.InsufficientETH();
            uint256[] memory amounts = SwapRouterLib.swapExactETHInBestRouteFromUserFromConfig(
                paymentToken,
                total,
                price,
                address(this)
            );
            if (amounts[amounts.length - 1] < price) revert Errors.Slippage();
            if (msg.value > total) {
                (bool ok,) = msg.sender.call{value: msg.value - total}("");
                require(ok);
            }
        } else {
            // Cross-token payment - swap via library wrappers
            uint256[] memory amounts = SwapRouterLib.swapExactInBestRouteFromUserFromConfig(
                inputToken,
                paymentToken,
                total,
                price,
                address(this)
            );
            if (amounts[amounts.length - 1] < price) revert Errors.Slippage();
        }

        // At this point we have the correct payment token and enough to pay for the listing

        // Seller pays fee: distribute price - fee to seller, fee to recipient
        if (marketFee > 0) {
            IERC20(paymentToken).safeTransfer(MarketStorage.configLayout().feeRecipient, marketFee);
        }

        // Transfer veNFT from seller wallet to buyer
        IVotingEscrowMinimalOpsWL(MarketStorage.configLayout().votingEscrow).transferFrom(listing.owner, msg.sender, tokenId);

        // Send net proceeds to seller (price - fee)
        IERC20(paymentToken).safeTransfer(listing.owner, price - marketFee);

        // Delete listing
        delete MarketStorage.orderbookLayout().listings[tokenId];

        emit ListingTaken(tokenId, msg.sender, price, marketFee);
    }

    function _calculateMarketFee(uint256 price) internal view returns (uint256 marketFee) {
        // TODO: calculate market fee
        return (price * MarketStorage.configLayout().marketFeeBps) / 10000;
    }
}


