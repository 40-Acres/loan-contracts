// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {MarketLogicLib} from "../../libraries/MarketLogicLib.sol";
import {IMarketListingsLoanFacet} from "../../interfaces/IMarketListingsLoanFacet.sol";
import {SwapRouterLib} from "../../libraries/SwapRouterLib.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface ILoanMinimalOpsLL {
    function getLoanDetails(uint256 tokenId) external view returns (uint256 balance, address borrower);
    function pay(uint256 tokenId, uint256 amount) external;
    function setBorrower(uint256 tokenId, address borrower) external;
}

interface IVotingEscrowMinimalOpsLL {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IPermit2MinimalLL {
    struct TokenPermissions { address token; uint256 amount; }
    struct PermitSingle { TokenPermissions permitted; uint256 nonce; uint256 deadline; address spender; }
    function permit(address owner, PermitSingle calldata permitSingle, bytes calldata signature) external;
    function transferFrom(address from, address to, uint160 amount, address token) external;
}

contract MarketListingsLoanFacet is IMarketListingsLoanFacet {
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

    function makeLoanListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt
    ) external nonReentrant onlyWhenNotPaused {
        require(MarketStorage.configLayout().allowedPaymentToken[paymentToken], "InvalidPaymentToken");
        if (expiresAt != 0) require(expiresAt > block.timestamp, "InvalidExpiration");

        address tokenOwner = MarketLogicLib.getTokenOwnerOrBorrower(tokenId);
        // TODO: custom error for unauthorized
        require(MarketLogicLib.canOperate(tokenOwner, msg.sender), "Unauthorized");

        // Ensure token is in Loan custody (not wallet): ownerOf(tokenId) != msg.sender
        // TODO: custom error for wallet held
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

    function takeLoanListing(uint256 tokenId, address inputToken) external payable nonReentrant onlyWhenNotPaused {
        _takeLoanListing(tokenId, msg.sender, inputToken);
    }

    function takeLoanListingWithPermit(uint256 tokenId, address inputToken, IPermit2MinimalLL.PermitSingle calldata permitSingle, bytes calldata signature) external payable nonReentrant onlyWhenNotPaused {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), "ListingNotFound");
        require(MarketLogicLib.isListingActive(tokenId), "ListingExpired");
        
        // full payoff path only
        (uint256 total, uint256 listingPrice, uint256 loanBalance, address paymentToken) = _getTotalCostOfListingAndDebt(tokenId);
        require(paymentToken == MarketStorage.configLayout().loanAsset || loanBalance == 0, "WrongPaymentAsset");

        if (inputToken == address(0)) {
            // ETH path; ignore permit
            _takeLoanListing(tokenId, msg.sender, inputToken);
            return;
        }

        require(MarketStorage.configLayout().allowedPaymentToken[inputToken], "InputTokenNotAllowed");
        require(msg.value == 0, "NoETHForTokenPayment");

        address permit2 = MarketStorage.configLayout().permit2;
        require(permit2 != address(0), "Permit2NotSet");
        IPermit2MinimalLL(permit2).permit(msg.sender, permitSingle, signature);
        IPermit2MinimalLL(permit2).transferFrom(msg.sender, address(this), uint160(total), inputToken);

        _settleLoanListing(tokenId, msg.sender, inputToken, total);
    }

    function quoteLoanListing(
        uint256 tokenId,
        address inputToken
    ) external view returns (
        uint256 listingPriceInPaymentToken,
        uint256 protocolFeeInPaymentToken,
        uint256 requiredInputTokenAmount,
        address paymentToken
    ) {
        return _quoteLoanListing(tokenId, inputToken);
    }

    function _getTotalCostOfListingAndDebt(uint256 tokenId) internal view returns (
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
            (loanBalance,) = ILoanMinimalOpsLL(MarketStorage.configLayout().loan).getLoanDetails(tokenId);
        }
        // TODO: calculate market fee
        total = listingPrice + loanBalance;
    }

    function _quoteLoanListing(
        uint256 tokenId,
        address inputToken
    ) internal view returns (
        uint256 listingPriceInPaymentToken,
        uint256 protocolFeeInPaymentToken,
        uint256 requiredInputTokenAmount,
        address paymentToken
    ) {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), "ListingNotFound");
        require(MarketLogicLib.isListingActive(tokenId), "ListingExpired");

        listingPriceInPaymentToken = listing.price;
        paymentToken = listing.paymentToken;
        (uint256 totalCost, , uint256 loanBalance, ) = _getTotalCostOfListingAndDebt(tokenId);
        address loanAsset = MarketStorage.configLayout().loanAsset;
        // Fee is denominated in listing currency; seller pays; not added on top.
        protocolFeeInPaymentToken = (listingPriceInPaymentToken * MarketStorage.configLayout().marketFeeBps) / 10000;

        if (inputToken == paymentToken) {
            // Buyer supplies listing token for price, plus extra listing token to cover loan payoff conversion
            uint256 listingForPayoff = SwapRouterLib.getAmountInForExactOutFromConfig(paymentToken, loanAsset, loanBalance);
            requiredInputTokenAmount = listingPriceInPaymentToken + listingForPayoff;
            return (listingPriceInPaymentToken, protocolFeeInPaymentToken, requiredInputTokenAmount, paymentToken);
        }
        if (inputToken == address(0)) {
            // ETH leg for price in listing token + ETH leg for loan payoff in USDC
            uint256 ethForListing = SwapRouterLib.getAmountInETHForExactOutFromConfig(paymentToken, listingPriceInPaymentToken);
            uint256 ethForLoan = SwapRouterLib.getAmountInETHForExactOutFromConfig(MarketStorage.configLayout().loanAsset, loanBalance);
            requiredInputTokenAmount = ethForListing + ethForLoan;
        } else {
            // ERC20 input: sum of input required for both legs
            uint256 inForListing = SwapRouterLib.getAmountInForExactOutFromConfig(inputToken, paymentToken, listingPriceInPaymentToken);
            uint256 inForLoan = SwapRouterLib.getAmountInForExactOutFromConfig(inputToken, loanAsset, loanBalance);
            requiredInputTokenAmount = inForListing + inForLoan;
        }
        return (listingPriceInPaymentToken, protocolFeeInPaymentToken, requiredInputTokenAmount, paymentToken);
    }

    function _takeLoanListing(uint256 tokenId, address buyer, address inputToken) internal {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), "ListingNotFound");
        require(MarketLogicLib.isListingActive(tokenId), "ListingExpired");
        _settleLoanListing(tokenId, buyer, inputToken, 0);
    }

    // Full payoff only
    function _settleLoanListing(uint256 tokenId, address buyer, address inputToken, uint256 prePulledAmount) internal {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        (uint256 total, uint256 listingPrice, uint256 loanBalance, address paymentToken) = _getTotalCostOfListingAndDebt(tokenId);
            require(MarketStorage.configLayout().loan != address(0), "LoanNotConfigured");
        address loanAsset = MarketStorage.configLayout().loanAsset;

        // If not pre-pulled, collect funds and/or swap via from-config helpers
        if (prePulledAmount == 0) {
            if (inputToken == address(0)) {
                // ETH path: split into two legs
                uint256 ethForListing = SwapRouterLib.getAmountInETHForExactOutFromConfig(paymentToken, listingPrice);
                uint256 ethForLoan = SwapRouterLib.getAmountInETHForExactOutFromConfig(loanAsset, loanBalance);
                require(msg.value >= ethForListing + ethForLoan, "InsufficientETH");
                // swap ETH -> listing token for price
                uint256[] memory a1 = SwapRouterLib.swapExactETHInBestRouteFromUserFromConfig(paymentToken, ethForListing, listingPrice, address(this));
                require(a1[a1.length - 1] >= listingPrice, "InsufficientSwapOutput");
                // swap ETH -> USDC for payoff
                uint256[] memory a2 = SwapRouterLib.swapExactETHInBestRouteFromUserFromConfig(loanAsset, ethForLoan, loanBalance, address(this));
                require(a2[a2.length - 1] >= loanBalance, "InsufficientSwapOutput");
                if (msg.value > ethForListing + ethForLoan) {
                    (bool ok,) = msg.sender.call{value: msg.value - (ethForListing + ethForLoan)}("");
                    require(ok);
                }
            } else if (inputToken == paymentToken) {
                // Pull listing token for price and convert part to USDC for payoff
                uint256 inForLoan = SwapRouterLib.getAmountInForExactOutFromConfig(paymentToken, loanAsset, loanBalance);
                IERC20(paymentToken).safeTransferFrom(buyer, address(this), listingPrice + inForLoan);
                uint256[] memory a = SwapRouterLib.swapExactInBestRouteFromConfig(paymentToken, loanAsset, inForLoan, loanBalance, address(this));
                require(a[a.length - 1] >= loanBalance, "InsufficientSwapOutput");
            } else {
                // Pull input token separately for both legs
                uint256 inForListing = SwapRouterLib.getAmountInForExactOutFromConfig(inputToken, paymentToken, listingPrice);
                uint256 inForLoan = SwapRouterLib.getAmountInForExactOutFromConfig(inputToken, loanAsset, loanBalance);
                uint256[] memory a1 = SwapRouterLib.swapExactInBestRouteFromUserFromConfig(inputToken, paymentToken, inForListing, listingPrice, address(this));
                require(a1[a1.length - 1] >= listingPrice, "InsufficientSwapOutput");
                uint256[] memory a2 = SwapRouterLib.swapExactInBestRouteFromUserFromConfig(inputToken, loanAsset, inForLoan, loanBalance, address(this));
                require(a2[a2.length - 1] >= loanBalance, "InsufficientSwapOutput");
            }
        }

        // Compute fee in listing currency based on listing price
        uint256 feeListing = (listingPrice * MarketStorage.configLayout().marketFeeBps) / 10000;

        // Pay off the loan if needed
        if (loanBalance > 0) {
            IERC20(loanAsset).approve(MarketStorage.configLayout().loan, loanBalance);
            ILoanMinimalOpsLL(MarketStorage.configLayout().loan).pay(tokenId, loanBalance);
        }

        // Distribute: fee in listing currency; seller gets remainder
        if (feeListing > 0) {
            IERC20(paymentToken).safeTransfer(MarketStorage.configLayout().feeRecipient, feeListing);
        }
        IERC20(paymentToken).safeTransfer(listing.owner, listingPrice - feeListing);

        // Assign borrower to buyer
        ILoanMinimalOpsLL(MarketStorage.configLayout().loan).setBorrower(tokenId, buyer);

        delete MarketStorage.orderbookLayout().listings[tokenId];
        emit ListingTaken(tokenId, buyer, listingPrice, feeListing);
    }
}


