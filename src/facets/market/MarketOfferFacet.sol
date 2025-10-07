// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {MarketLogicLib} from "../../libraries/MarketLogicLib.sol";
import {IMarketOfferFacet} from "../../interfaces/IMarketOfferFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FeeLib} from "../../libraries/FeeLib.sol";
import {RouteLib} from "../../libraries/RouteLib.sol";
import {AccessRoleLib} from "../../libraries/AccessRoleLib.sol";
import "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {ILoan} from "../../interfaces/ILoan.sol";
import {IVotingEscrow} from "../../interfaces/IVotingEscrow.sol";
import {Errors} from "../../libraries/Errors.sol";

contract MarketOfferFacet is IMarketOfferFacet {
    using SafeERC20 for IERC20;

    modifier onlyWhenNotPaused() {
        require(!MarketStorage.managerPauseLayout().marketPaused, Errors.Paused());
        _;
    }

    modifier nonReentrant() {
        MarketStorage.MarketPauseLayout storage pause = MarketStorage.managerPauseLayout();
        require(pause.reentrancyStatus != 2, Errors.Reentrancy());
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

    function createOffer(
        uint256 minWeight,
        uint256 debtTolerance,
        uint256 price,
        address paymentToken,
        uint256 expiresAt
    ) external payable nonReentrant onlyWhenNotPaused {
        require(MarketStorage.configLayout().allowedPaymentToken[paymentToken], Errors.InvalidPaymentToken());
        require(minWeight > 0, Errors.InsufficientWeight());
        if (expiresAt != 0) require(expiresAt > block.timestamp, Errors.InvalidExpiration());
        
        // If accepting loans with debt, payment token must match the loan asset
        // Note: loanAsset can only be set if loan is configured (enforced in setLoanAsset)
        if (debtTolerance > 0) {
            address loanAsset = MarketStorage.configLayout().loanAsset;
            require(loanAsset != address(0), Errors.LoanNotConfigured());
            require(paymentToken == loanAsset, Errors.InvalidPaymentToken());
        }

        // Approval-based offers: no escrow pull at creation

        uint256 offerId = ++MarketStorage.orderbookLayout()._offerCounter;
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        offer.creator = msg.sender;
        offer.minWeight = minWeight;
        offer.debtTolerance = debtTolerance;
        offer.price = price;
        offer.paymentToken = paymentToken;
        offer.expiresAt = expiresAt;
        offer.offerId = offerId;

        emit OfferCreated(offerId, msg.sender, minWeight, debtTolerance, price, paymentToken, expiresAt);
    }

    function updateOffer(
        uint256 offerId,
        uint256 newMinWeight,
        uint256 newDebtTolerance,
        uint256 newPrice,
        address newPaymentToken,
        uint256 newExpiresAt
    ) external nonReentrant onlyWhenNotPaused {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        require(offer.creator != address(0), Errors.OfferNotFound());
        require(MarketLogicLib.canOperate(offer.creator, msg.sender), Errors.NotAuthorized());
        require(MarketStorage.configLayout().allowedPaymentToken[newPaymentToken], Errors.InvalidPaymentToken());
        require(newMinWeight > 0, Errors.InsufficientWeight());
        if (newExpiresAt != 0) require(newExpiresAt > block.timestamp, Errors.InvalidExpiration());
        
        // If accepting loans with debt, payment token must match the loan asset
        // Note: loanAsset can only be set if loan is configured (enforced in setLoanAsset)
        if (newDebtTolerance > 0) {
            address loanAsset = MarketStorage.configLayout().loanAsset;
            require(loanAsset != address(0), Errors.LoanNotConfigured());
            require(newPaymentToken == loanAsset, Errors.InvalidPaymentToken());
        }

        // Approval-based offers: price changes do not move funds at update time

        offer.minWeight = newMinWeight;
        offer.debtTolerance = newDebtTolerance;
        offer.price = newPrice;
        offer.paymentToken = newPaymentToken;
        offer.expiresAt = newExpiresAt;

        emit OfferUpdated(offerId, newMinWeight, newDebtTolerance, newPrice, newPaymentToken, newExpiresAt);
    }

    function cancelOffer(uint256 offerId) external nonReentrant {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        require(offer.creator != address(0), Errors.OfferNotFound());
        require(MarketLogicLib.canOperate(offer.creator, msg.sender), Errors.NotAuthorized());
        // Approval-based offers: nothing to refund; just delete the offer
        delete MarketStorage.orderbookLayout().offers[offerId];
        emit OfferCancelled(offerId);
    }

    function cancelExpiredOffers(uint256[] calldata offerIds) external nonReentrant onlyMarketAdmin {
        for (uint256 i = 0; i < offerIds.length; i++) {
            uint256 offerId = offerIds[i];
            MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
            if (offer.creator != address(0) && offer.expiresAt != 0 && block.timestamp >= offer.expiresAt) {
                delete MarketStorage.orderbookLayout().offers[offerId];
                emit OfferCancelled(offerId);
            }
        }
    }

    function acceptOffer(uint256 tokenId, uint256 offerId, bool isInLoanV2, uint256 expectedPrice, address expectedPaymentToken) external nonReentrant onlyWhenNotPaused {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        require(offer.creator != address(0), Errors.OfferNotFound());
        require(MarketLogicLib.isOfferActive(offerId), Errors.OfferExpired());
        require(expectedPrice == offer.price, Errors.InvalidPrice());
        require(expectedPaymentToken == offer.paymentToken, Errors.InvalidPaymentToken());
        
        address tokenOwner = MarketLogicLib.getTokenOwnerOrBorrower(tokenId);
        require(MarketLogicLib.canOperate(tokenOwner, msg.sender), Errors.NotAuthorized());

        _validateOfferCriteria(tokenId, offer, isInLoanV2);

        // Get loan balance to calculate total amount buyer must provide
        uint256 loanBalance = 0;
        if (isInLoanV2) {
            address loanAddr = MarketStorage.configLayout().loan;
            require(loanAddr != address(0), Errors.LoanNotConfigured());
            
            (loanBalance,) = ILoan(loanAddr).getLoanDetails(tokenId);
            if (loanBalance > 0) {
                address loanAsset = MarketStorage.configLayout().loanAsset;
                // Ensure payment token matches loan asset (enforced at offer creation)
                require(offer.paymentToken == loanAsset, Errors.InvalidPaymentToken());
            }
        }

        // Pull total amount from buyer: offer price + any outstanding debt
        uint256 totalFromBuyer = offer.price + loanBalance;
        IERC20(offer.paymentToken).safeTransferFrom(offer.creator, address(this), totalFromBuyer);
        
        // Pay off loan debt separately if it exists
        if (loanBalance > 0) {
            address loanContract = MarketStorage.configLayout().loan;
            IERC20(offer.paymentToken).forceApprove(loanContract, loanBalance);
            ILoan(loanContract).pay(tokenId, loanBalance);
            IERC20(offer.paymentToken).forceApprove(loanContract, 0);
        }
        
        // Seller receives full offer price minus protocol fee (debt paid separately)
        uint256 fee = FeeLib.calculateFee(RouteLib.BuyRoute.InternalWallet, offer.price);
        uint256 sellerAmount = offer.price - fee;
        
        if (fee > 0) {
            IERC20(offer.paymentToken).safeTransfer(FeeLib.feeRecipient(), fee);
        }
        IERC20(offer.paymentToken).safeTransfer(tokenOwner, sellerAmount);

        if (isInLoanV2) {
            ILoan(MarketStorage.configLayout().loan).finalizeOfferPurchase(tokenId, offer.creator, tokenOwner, offerId);
        } else {
            IVotingEscrow(MarketStorage.configLayout().votingEscrow).transferFrom(tokenOwner, offer.creator, tokenId);
        }

        delete MarketStorage.orderbookLayout().offers[offerId];
        emit OfferAccepted(offerId, tokenId, tokenOwner, offer.price, fee);
    }

    function _validateOfferCriteria(uint256 tokenId, MarketStorage.Offer storage offer, bool isInLoanV2) internal view {
        address loanAddr = MarketStorage.configLayout().loan;
        
        uint256 weight = isInLoanV2
            ? ILoan(loanAddr).getLoanWeight(tokenId)
            : MarketLogicLib.getVeNFTWeight(tokenId);
        require(weight >= offer.minWeight, Errors.InsufficientWeight());
        
        // Only check loan balance if loan contract is configured
        if (loanAddr != address(0)) {
            (uint256 loanBalance,) = ILoan(loanAddr).getLoanDetails(tokenId);
            require(loanBalance <= offer.debtTolerance, Errors.InsufficientDebtTolerance());
        }
        // If no loan contract, loanBalance is effectively 0, which always satisfies debtTolerance >= 0
        
        IVotingEscrow.LockedBalance memory lockedBalance = IVotingEscrow(MarketStorage.configLayout().votingEscrow).locked(tokenId);
    }
}


