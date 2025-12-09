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
import {Permit2Lib, IPermit2} from "../../libraries/Permit2Lib.sol";
import {AccessRoleLib} from "../../libraries/AccessRoleLib.sol";
import "lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import {ILoan} from "../../interfaces/ILoan.sol";
import {IVotingEscrow} from "../../interfaces/IVotingEscrow.sol";
import {IPortfolioMarketplaceFacet} from "../../interfaces/IPortfolioMarketplaceFacet.sol";
import {PortfolioFactory} from "../../accounts/PortfolioFactory.sol";

/**
 * @title MarketListingsLoanFacet
 * @dev Handles marketplace listings for veNFTs held by portfolio accounts
 * Portfolio accounts hold veNFTs and track collateral via CollateralManager
 */
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

    modifier onlyMarketAdmin() {
        address accessManager = MarketStorage.configLayout().accessManager;
        if (accessManager != address(0)) {
            (bool hasRole,) = IAccessManager(accessManager).hasRole(AccessRoleLib.MARKET_ADMIN, msg.sender);
            if (hasRole) {
                _;
                return;
            }
        }
        revert Errors.NotAuthorized();
    }

    /**
     * @notice Create a listing for a veNFT held by a portfolio account
     * @dev The caller must be the portfolio owner or have operator approval
     * @param tokenId The veNFT token ID
     * @param price The listing price in paymentToken
     * @param paymentToken The token to receive payment in
     * @param expiresAt Listing expiration timestamp (0 = never)
     * @param allowedBuyer Optional address restriction for buyer
     */
    function makeLoanListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt,
        address allowedBuyer
    ) external nonReentrant onlyWhenNotPaused {
        if (!MarketStorage.configLayout().allowedPaymentToken[paymentToken]) revert Errors.CurrencyNotAllowed();
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert Errors.InvalidExpiration();

        MarketStorage.MarketConfigLayout storage cfg = MarketStorage.configLayout();
        
        // Get the veNFT owner (should be a portfolio)
        address veNFTOwner = IVotingEscrow(cfg.votingEscrow).ownerOf(tokenId);
        
        // Verify the veNFT is held by a portfolio
        PortfolioFactory factory = PortfolioFactory(cfg.portfolioFactory);
        if (!factory.isPortfolio(veNFTOwner)) revert Errors.BadCustody();
        
        // Authorization: caller must be portfolio, portfolio owner, or approved operator
        if (!MarketLogicLib.canOperate(veNFTOwner, msg.sender)) revert Errors.NotAuthorized();

        // Check for outstanding loan balance
        (uint256 balance,) = ILoan(cfg.loan).getLoanDetails(tokenId);
        bool hasOutstandingLoan = balance > 0;

        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        listing.owner = veNFTOwner; // Portfolio address is the listing owner
        listing.tokenId = tokenId;
        listing.price = price;
        listing.paymentToken = paymentToken;
        listing.hasOutstandingLoan = hasOutstandingLoan;
        listing.expiresAt = expiresAt;
        listing.allowedBuyer = allowedBuyer;
        
        emit ListingCreated(tokenId, veNFTOwner, price, paymentToken, hasOutstandingLoan, expiresAt, allowedBuyer);
    }

    function updateLoanListing(
        uint256 tokenId,
        uint256 newPrice,
        address newPaymentToken,
        uint256 newExpiresAt,
        address newAllowedBuyer
    ) external nonReentrant onlyWhenNotPaused {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        if (listing.owner == address(0)) revert Errors.ListingNotFound();
        if (!MarketLogicLib.canOperate(listing.owner, msg.sender)) revert Errors.NotAuthorized();
        
        require(MarketStorage.configLayout().allowedPaymentToken[newPaymentToken], Errors.InvalidPaymentToken());
        if (newExpiresAt != 0) require(newExpiresAt > block.timestamp, Errors.InvalidExpiration());

        listing.price = newPrice;
        listing.paymentToken = newPaymentToken;
        listing.expiresAt = newExpiresAt;
        listing.allowedBuyer = newAllowedBuyer;

        emit ListingUpdated(tokenId, newPrice, newPaymentToken, newExpiresAt, newAllowedBuyer);
    }

    function cancelLoanListing(uint256 tokenId) external nonReentrant {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), Errors.ListingNotFound());
        require(MarketLogicLib.canOperate(listing.owner, msg.sender), Errors.NotAuthorized());
        delete MarketStorage.orderbookLayout().listings[tokenId];
        emit ListingCancelled(tokenId);
    }

    function cancelExpiredLoanListings(uint256[] calldata listingIds) external nonReentrant onlyMarketAdmin {
        for (uint256 i = 0; i < listingIds.length; i++) {
            uint256 tokenId = listingIds[i];
            MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
            if (listing.owner != address(0) && listing.expiresAt != 0 && block.timestamp >= listing.expiresAt) {
                delete MarketStorage.orderbookLayout().listings[tokenId];
                emit ListingCancelled(tokenId);
            }
        }
    }

    function takeLoanListing(
        uint256 tokenId,
        address inputToken,
        uint256 amountInMax,
        bytes calldata tradeData,
        bytes calldata optionalPermit2
    ) public payable nonReentrant onlyWhenNotPaused {
        _takeLoanListingFor(tokenId, msg.sender, inputToken, amountInMax, tradeData, optionalPermit2);
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
        _takeLoanListingFor(tokenId, buyer, inputToken, amountInMax, tradeData, optionalPermit2);
    }

    function _takeLoanListingFor(
        uint256 tokenId,
        address buyer,
        address inputToken,
        uint256 amountInMax,
        bytes memory tradeData,
        bytes memory optionalPermit2
    ) internal {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        if (listing.owner == address(0)) revert Errors.ListingNotFound();
        if (listing.allowedBuyer != address(0) && listing.allowedBuyer != buyer) revert Errors.NotAllowedBuyer();
        if (!MarketLogicLib.isListingActive(tokenId)) revert Errors.ListingExpired();
        
        (uint256 total, uint256 listingPrice, uint256 loanBalance, address paymentToken) = _getTotalCostOfListingAndDebt(tokenId);

        MarketStorage.MarketConfigLayout storage cfg = MarketStorage.configLayout();

        if (inputToken == paymentToken && tradeData.length == 0) {
            // Pull exactly listing price + loan payoff; seller pays protocol fee from proceeds
            Permit2Lib.permitAndPull(buyer, address(this), inputToken, total, optionalPermit2);
            if (optionalPermit2.length == 0) {
                IERC20(inputToken).safeTransferFrom(buyer, address(this), total);
            }
            // If there is outstanding loan balance, pay it directly in the same currency
            if (loanBalance > 0) {
                address loanAsset = cfg.loanAsset;
                if (loanAsset != paymentToken) revert Errors.NoValidRoute();
                IERC20(loanAsset).approve(cfg.loan, loanBalance);
                ILoan(cfg.loan).pay(tokenId, loanBalance);
            }
        } else if (tradeData.length > 0) {
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
            // After Odos, require balances sufficient for listing price + loan payoff
            address loanAsset = cfg.loanAsset;
            if (IERC20(paymentToken).balanceOf(address(this)) < listingPrice) revert Errors.Slippage();
            if (loanBalance > 0 && IERC20(loanAsset).balanceOf(address(this)) < loanBalance) revert Errors.Slippage();
            if (loanBalance > 0) {
                IERC20(loanAsset).approve(cfg.loan, loanBalance);
                ILoan(cfg.loan).pay(tokenId, loanBalance);
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
        
        // Finalize purchase through the portfolio's MarketplaceFacet
        // The portfolio handles veNFT transfer and collateral tracking updates
        IPortfolioMarketplaceFacet(listing.owner).finalizeMarketPurchase(tokenId, buyer, listing.owner);
        
        delete MarketStorage.orderbookLayout().listings[tokenId];
        emit ListingTaken(tokenId, buyer, listingPrice, feeListing);
    }

    function takeLoanListingWithPermit(
        uint256 tokenId,
        address inputToken,
        IMarketListingsLoanFacet.PermitSingle calldata permitSingle,
        bytes calldata signature
    ) external payable nonReentrant onlyWhenNotPaused {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        if (listing.owner == address(0)) revert Errors.ListingNotFound();
        if (!MarketLogicLib.isListingActive(tokenId)) revert Errors.ListingExpired();
        
        // full payoff path only
        (uint256 total, uint256 listingPrice, uint256 loanBalance, address paymentToken) = _getTotalCostOfListingAndDebt(tokenId);
        require(paymentToken == MarketStorage.configLayout().loanAsset || loanBalance == 0, Errors.WrongPaymentAsset());

        if (inputToken == address(0)) {
            // ETH path; ignore permit
            _takeLoanListing(tokenId, msg.sender, inputToken);
            return;
        }

        require(MarketStorage.configLayout().allowedPaymentToken[inputToken], Errors.InputTokenNotAllowed());
        require(msg.value == 0, Errors.NoETHForTokenPayment());

        // Encode permit payload and use Permit2Lib to perform permit+pull.
        IPermit2.PermitSingle memory p2 = IPermit2.PermitSingle({
            permitted: IPermit2.TokenPermissions({ token: permitSingle.permitted.token, amount: permitSingle.permitted.amount }),
            nonce: permitSingle.nonce,
            deadline: permitSingle.deadline,
            spender: permitSingle.spender
        });
        bytes memory encodedPermit = abi.encode(p2, signature);
        Permit2Lib.permitAndPull(msg.sender, address(this), inputToken, total, encodedPermit);

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
        require(listing.owner != address(0), Errors.ListingNotFound());
        listingPrice = listing.price;
        paymentToken = listing.paymentToken;
        if (listing.hasOutstandingLoan) {
            (loanBalance,) = ILoan(MarketStorage.configLayout().loan).getLoanDetails(tokenId);
        }
        total = listingPrice + loanBalance;
    }


    function _takeLoanListing(uint256 tokenId, address buyer, address inputToken) internal {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        require(listing.owner != address(0), Errors.ListingNotFound());
        require(MarketLogicLib.isListingActive(tokenId), Errors.ListingExpired());
        _settleLoanListing(tokenId, buyer, inputToken, 0);
    }

    // Settlement: supports no-swap path; swap path handled in takeLoanListing with Odos
    function _settleLoanListing(uint256 tokenId, address buyer, address inputToken, uint256 prePulledAmount) internal {
        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        ( , uint256 listingPrice, uint256 loanBalance, address paymentToken) = _getTotalCostOfListingAndDebt(tokenId);
        
        MarketStorage.MarketConfigLayout storage cfg = MarketStorage.configLayout();
        if (cfg.loan == address(0)) revert Errors.LoanNotConfigured();
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

        // Finalize purchase through the portfolio's MarketplaceFacet
        IPortfolioMarketplaceFacet(listing.owner).finalizeMarketPurchase(tokenId, buyer, listing.owner);

        delete MarketStorage.orderbookLayout().listings[tokenId];
        emit ListingTaken(tokenId, buyer, listingPrice, feeListing);
    }
}
