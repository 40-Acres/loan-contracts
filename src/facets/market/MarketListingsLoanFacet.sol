// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {MarketLogicLib} from "../../libraries/MarketLogicLib.sol";
import {IMarketListingsLoanFacet} from "../../interfaces/IMarketListingsLoanFacet.sol";
import {Errors} from "../../libraries/Errors.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {FeeLib} from "../../libraries/FeeLib.sol";
import {RouteLib} from "../../libraries/RouteLib.sol";

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
        if (!MarketStorage.configLayout().allowedPaymentToken[paymentToken]) revert Errors.CurrencyNotAllowed();
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert Errors.InvalidExpiration();

        address tokenOwner = MarketLogicLib.getTokenOwnerOrBorrower(tokenId);
        if (!MarketLogicLib.canOperate(tokenOwner, msg.sender)) revert Errors.NotAuthorized();

        // Ensure token is in Loan custody (not wallet): ownerOf(tokenId) != msg.sender
        if (IVotingEscrowMinimalOpsLL(MarketStorage.configLayout().votingEscrow).ownerOf(tokenId) == msg.sender) revert Errors.BadCustody();

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
        if (listing.owner == address(0)) revert Errors.ListingNotFound();
        if (!MarketLogicLib.canOperate(listing.owner, msg.sender)) revert Errors.NotAuthorized();
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
        _takeLoanUnifiedFor(tokenId, msg.sender, inputToken, 0, new bytes(0), new bytes(0));
    }

    function takeLoanListing(
        uint256 tokenId,
        address inputToken,
        uint256 amountInMax,
        bytes calldata tradeData,
        bytes calldata optionalPermit2
    ) public payable nonReentrant onlyWhenNotPaused {
        _takeLoanUnifiedFor(tokenId, msg.sender, inputToken, amountInMax, tradeData, optionalPermit2);
    }

    function takeLoanListingFor(
        uint256 tokenId,
        address buyer,
        address inputToken,
        uint256 amountInMax,
        bytes calldata tradeData,
        bytes calldata optionalPermit2
    ) external payable nonReentrant onlyWhenNotPaused {
        if (msg.sender != address(this)) revert Errors.NotAuthorized();
        _takeLoanUnifiedFor(tokenId, buyer, inputToken, amountInMax, tradeData, optionalPermit2);
    }

    function _takeLoanUnifiedFor(
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
        (uint256 total, uint256 listingPrice, uint256 loanBalance, address paymentToken) = _getTotalCostOfListingAndDebt(tokenId);

        IPermit2MinimalLL.PermitSingle memory p2; bytes memory sig;
        if (optionalPermit2.length > 0) {
            (p2, sig) = abi.decode(optionalPermit2, (IPermit2MinimalLL.PermitSingle, bytes));
        }

        if (inputToken == paymentToken && tradeData.length == 0) {
            if (inputToken == address(0)) {
                if (msg.value < total) revert Errors.InsufficientETH();
            } else {
                if (optionalPermit2.length > 0) {
                    address permit2 = MarketStorage.configLayout().permit2;
                    if (permit2 == address(0)) revert Errors.Permit2NotSet();
                    IPermit2MinimalLL(permit2).permit(buyer, p2, sig);
                    IPermit2MinimalLL(permit2).transferFrom(buyer, address(this), uint160(total), inputToken);
                } else {
                    IERC20(inputToken).safeTransferFrom(buyer, address(this), total);
                }
            }
        } else if (tradeData.length > 0) {
            address odos = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;
            if (inputToken == address(0)) {
                if (msg.value == 0) revert Errors.InsufficientETH();
                (bool success,) = odos.call{value: msg.value}(tradeData);
                require(success);
            } else {
                if (optionalPermit2.length > 0) {
                    address permit2 = MarketStorage.configLayout().permit2;
                    if (permit2 == address(0)) revert Errors.Permit2NotSet();
                    IPermit2MinimalLL(permit2).permit(buyer, p2, sig);
                    IPermit2MinimalLL(permit2).transferFrom(buyer, address(this), uint160(amountInMax), inputToken);
                } else {
                    IERC20(inputToken).safeTransferFrom(buyer, address(this), amountInMax);
                }
                IERC20(inputToken).approve(odos, amountInMax);
                (bool success2,) = odos.call{value: 0}(tradeData);
                require(success2);
                IERC20(inputToken).approve(odos, 0);
            }
            // After Odos, require balances sufficient for listing price + loan payoff
            address loanAsset = MarketStorage.configLayout().loanAsset;
            if (IERC20(paymentToken).balanceOf(address(this)) < listingPrice) revert Errors.Slippage();
            if (loanBalance > 0 && IERC20(loanAsset).balanceOf(address(this)) < loanBalance) revert Errors.Slippage();
            if (loanBalance > 0) {
                IERC20(loanAsset).approve(MarketStorage.configLayout().loan, loanBalance);
                ILoanMinimalOpsLL(MarketStorage.configLayout().loan).pay(tokenId, loanBalance);
            }
        } else {
            revert Errors.InvalidRoute();
        }

        // Settle listing proceeds
        uint256 feeListing = FeeLib.calculateFee(RouteLib.BuyRoute.InternalLoan, listingPrice);
        if (feeListing > 0) {
            IERC20(paymentToken).safeTransfer(FeeLib.feeRecipient(), feeListing);
        }
        IERC20(paymentToken).safeTransfer(listing.owner, listingPrice - feeListing);
        ILoanMinimalOpsLL(MarketStorage.configLayout().loan).setBorrower(tokenId, buyer);
        delete MarketStorage.orderbookLayout().listings[tokenId];
        emit ListingTaken(tokenId, buyer, listingPrice, feeListing);
    }

    function takeLoanListingWithPermit(uint256 tokenId, address inputToken, IMarketListingsLoanFacet.PermitSingle calldata permitSingle, bytes calldata signature) external payable nonReentrant onlyWhenNotPaused {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        if (listing.owner == address(0)) revert Errors.ListingNotFound();
        if (!MarketLogicLib.isListingActive(tokenId)) revert Errors.ListingExpired();
        
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
        IPermit2MinimalLL.PermitSingle memory p2 = IPermit2MinimalLL.PermitSingle({
            permitted: IPermit2MinimalLL.TokenPermissions({token: permitSingle.permitted.token, amount: permitSingle.permitted.amount}),
            nonce: permitSingle.nonce,
            deadline: permitSingle.deadline,
            spender: permitSingle.spender
        });
        IPermit2MinimalLL(permit2).permit(msg.sender, p2, signature);
        IPermit2MinimalLL(permit2).transferFrom(msg.sender, address(this), uint160(total), inputToken);

        _settleLoanListing(tokenId, msg.sender, inputToken, total);
    }

    function quoteLoanListing(
        uint256 tokenId,
        address /*inputToken*/
    ) external view returns (
        uint256 listingPriceInPaymentToken,
        uint256 protocolFeeInPaymentToken,
        uint256 requiredInputTokenAmount,
        address paymentToken
    ) {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        if (listing.owner == address(0)) revert Errors.ListingNotFound();
        if (!MarketLogicLib.isListingActive(tokenId)) revert Errors.ListingExpired();
        (uint256 total, uint256 listingPrice, uint256 loanBalance, address payToken) = _getTotalCostOfListingAndDebt(tokenId);
        address loanAsset = MarketStorage.configLayout().loanAsset;
        // Only quote when no cross-asset payoff required (i.e., payoff asset equals listing payment token)
        if (loanBalance > 0 && loanAsset != payToken) revert Errors.NoValidRoute();
        listingPriceInPaymentToken = listingPrice;
        protocolFeeInPaymentToken = FeeLib.calculateFee(RouteLib.BuyRoute.InternalLoan, listingPrice);
        requiredInputTokenAmount = total;
        paymentToken = payToken;
        return (listingPriceInPaymentToken, protocolFeeInPaymentToken, requiredInputTokenAmount, paymentToken);
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

    // Removed swap-based quoting. Use Odos for swap-required cases.

    function _takeLoanListing(uint256 tokenId, address buyer, address inputToken) internal {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), "ListingNotFound");
        require(MarketLogicLib.isListingActive(tokenId), "ListingExpired");
        _settleLoanListing(tokenId, buyer, inputToken, 0);
    }

    // Settlement: supports no-swap path; swap path handled in new unified entry with Odos
    function _settleLoanListing(uint256 tokenId, address buyer, address inputToken, uint256 prePulledAmount) internal {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        ( , uint256 listingPrice, uint256 loanBalance, address paymentToken) = _getTotalCostOfListingAndDebt(tokenId);
        if (MarketStorage.configLayout().loan == address(0)) revert Errors.LoanNotConfigured();
        if (loanBalance > 0) revert Errors.NoValidRoute();
        if (prePulledAmount == 0) {
            require(inputToken == paymentToken && inputToken != address(0));
            IERC20(paymentToken).safeTransferFrom(buyer, address(this), listingPrice);
        }

        // Compute fee in listing currency based on listing price
        uint256 feeListing = FeeLib.calculateFee(RouteLib.BuyRoute.InternalLoan, listingPrice);

        // Distribute: fee in listing currency; seller gets remainder
        if (feeListing > 0) {
            IERC20(paymentToken).safeTransfer(FeeLib.feeRecipient(), feeListing);
        }
        IERC20(paymentToken).safeTransfer(listing.owner, listingPrice - feeListing);

        // Assign borrower to buyer
        ILoanMinimalOpsLL(MarketStorage.configLayout().loan).setBorrower(tokenId, buyer);

        delete MarketStorage.orderbookLayout().listings[tokenId];
        emit ListingTaken(tokenId, buyer, listingPrice, feeListing);
    }
}


