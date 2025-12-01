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
import {PortfolioFactory} from "../../accounts/PortfolioFactory.sol";
import {IPortfolioMarketplaceFacet} from "../../interfaces/IPortfolioMarketplaceFacet.sol";
import {Errors} from "../../libraries/Errors.sol";

/**
 * @title MarketOfferFacet
 * @dev Handles marketplace offers for veNFTs
 * Supports offers that can be accepted by portfolio owners or wallet holders
 */
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
        if (debtTolerance > 0) {
            require(paymentToken == MarketStorage.configLayout().loanAsset, Errors.InvalidPaymentToken());
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
        if (newDebtTolerance > 0) {
            require(newPaymentToken == MarketStorage.configLayout().loanAsset, Errors.InvalidPaymentToken());
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

    /**
     * @notice Accept an offer for a veNFT
     * @param tokenId The veNFT token ID
     * @param offerId The offer ID to accept
     * @param isInPortfolio True if the veNFT is held by a portfolio, false if in wallet
     */
    function acceptOffer(uint256 tokenId, uint256 offerId, bool isInPortfolio) external nonReentrant onlyWhenNotPaused {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        require(offer.creator != address(0), Errors.OfferNotFound());
        require(MarketLogicLib.isOfferActive(offerId), Errors.OfferExpired());

        MarketStorage.MarketConfigLayout storage cfg = MarketStorage.configLayout();
        
        // Get the veNFT owner (portfolio or wallet)
        address tokenOwner = IVotingEscrow(cfg.votingEscrow).ownerOf(tokenId);
        
        if (isInPortfolio) {
            // Verify the veNFT is held by a portfolio
            PortfolioFactory factory = PortfolioFactory(cfg.portfolioFactory);
            require(factory.isPortfolio(tokenOwner), Errors.BadCustody());
        }
        
        // Authorization: uses centralized canOperate which handles portfolios
        require(MarketLogicLib.canOperate(tokenOwner, msg.sender), Errors.NotAuthorized());

        _validateOfferCriteria(tokenId, offer, isInPortfolio);

        // Get loan balance to calculate total amount buyer must provide
        uint256 loanBalance = 0;
        if (isInPortfolio) {
            (loanBalance,) = ILoan(cfg.loan).getLoanDetails(tokenId);
            if (loanBalance > 0) {
                address loanAsset = cfg.loanAsset;
                // Ensure payment token matches loan asset (enforced at offer creation)
                require(offer.paymentToken == loanAsset, Errors.InvalidPaymentToken());
            }
        }

        // Pull total amount from buyer: offer price + any outstanding debt
        uint256 totalFromBuyer = offer.price + loanBalance;
        IERC20(offer.paymentToken).safeTransferFrom(offer.creator, address(this), totalFromBuyer);
        
        // Pay off loan debt separately if it exists
        if (loanBalance > 0) {
            IERC20(offer.paymentToken).forceApprove(cfg.loan, loanBalance);
            ILoan(cfg.loan).pay(tokenId, loanBalance);
            IERC20(offer.paymentToken).forceApprove(cfg.loan, 0);
        }
        
        // Seller receives full offer price minus protocol fee (debt paid separately)
        uint256 fee = FeeLib.calculateFee(RouteLib.BuyRoute.InternalWallet, offer.price);
        uint256 sellerAmount = offer.price - fee;
        
        if (fee > 0) {
            IERC20(offer.paymentToken).safeTransfer(FeeLib.feeRecipient(), fee);
        }
        IERC20(offer.paymentToken).safeTransfer(tokenOwner, sellerAmount);

        if (isInPortfolio) {
            // Finalize through the portfolio's MarketplaceFacet
            IPortfolioMarketplaceFacet(tokenOwner).finalizeOfferPurchase(tokenId, offer.creator, tokenOwner, offerId);
        } else {
            // Direct wallet transfer
            IVotingEscrow(cfg.votingEscrow).transferFrom(tokenOwner, offer.creator, tokenId);
        }

        delete MarketStorage.orderbookLayout().offers[offerId];
        emit OfferAccepted(offerId, tokenId, tokenOwner, offer.price, fee);
    }

    function _validateOfferCriteria(uint256 tokenId, MarketStorage.Offer storage offer, bool isInPortfolio) internal view {
        MarketStorage.MarketConfigLayout storage cfg = MarketStorage.configLayout();
        
        uint256 weight;
        if (isInPortfolio) {
            weight = ILoan(cfg.loan).getLoanWeight(tokenId);
        } else {
            weight = MarketLogicLib.getVeNFTWeight(tokenId);
        }
        require(weight >= offer.minWeight, Errors.InsufficientWeight());
        
        (uint256 loanBalance,) = ILoan(cfg.loan).getLoanDetails(tokenId);
        require(loanBalance <= offer.debtTolerance, Errors.InsufficientDebtTolerance());
        
        // Verify the lock is valid
        IVotingEscrow.LockedBalance memory lockedBalance = IVotingEscrow(cfg.votingEscrow).locked(tokenId);
    }
}