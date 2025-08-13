// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {MarketLogicLib} from "../../libraries/MarketLogicLib.sol";
import {IMarketOfferFacet} from "../../interfaces/IMarketOfferFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ILoanMinimalOpsOF {
    function getLoanDetails(uint256 tokenId) external view returns (uint256 balance, address borrower);
    function getLoanWeight(uint256 tokenId) external view returns (uint256 weight);
    function setBorrower(uint256 tokenId, address borrower) external;
}

interface IVotingEscrowMinimalOpsOF {
    struct LockedBalance { int128 amount; uint256 end; bool isPermanent; }
    function locked(uint256 _tokenId) external view returns (LockedBalance memory);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

contract MarketOfferFacet is IMarketOfferFacet {
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

        // Approval-based offers: no escrow pull at creation

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

        // Approval-based offers: price changes do not move funds at update time

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
        // Approval-based offers: nothing to refund; just delete the offer
        delete MarketStorage.orderbookLayout().offers[offerId];
        emit OfferCancelled(offerId);
    }

    function acceptOffer(uint256 tokenId, uint256 offerId, bool isInLoanV2) external nonReentrant onlyWhenNotPaused {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        require(offer.creator != address(0), "OfferNotFound");
        require(MarketLogicLib.isOfferActive(offerId), "OfferExpired");

        address tokenOwner = MarketLogicLib.getTokenOwnerOrBorrower(tokenId);
        require(MarketLogicLib.canOperate(tokenOwner, msg.sender), "Unauthorized");

        _validateOfferCriteria(tokenId, offer, isInLoanV2);

        // Pull full offer amount at fill time from offer creator
        IERC20(offer.paymentToken).safeTransferFrom(offer.creator, address(this), offer.price);
        uint256 fee = (offer.price * MarketStorage.configLayout().marketFeeBps) / 10000;
        uint256 sellerAmount = offer.price - fee;
        if (fee > 0) {
            IERC20(offer.paymentToken).safeTransfer(MarketStorage.configLayout().feeRecipient, fee);
        }
        IERC20(offer.paymentToken).safeTransfer(msg.sender, sellerAmount);

        if (isInLoanV2) {
            ILoanMinimalOpsOF(MarketStorage.configLayout().loan).setBorrower(tokenId, offer.creator);
        } else {
            IVotingEscrowMinimalOpsOF(MarketStorage.configLayout().votingEscrow).transferFrom(msg.sender, offer.creator, tokenId);
        }

        delete MarketStorage.orderbookLayout().offers[offerId];
        emit OfferAccepted(offerId, tokenId, msg.sender, offer.price, fee);
    }

    function _validateOfferCriteria(uint256 tokenId, MarketStorage.Offer storage offer, bool isInLoanV2) internal view {
        uint256 weight = isInLoanV2
            ? ILoanMinimalOpsOF(MarketStorage.configLayout().loan).getLoanWeight(tokenId)
            : MarketLogicLib.getVeNFTWeight(tokenId);
        require(weight >= offer.minWeight, "InsufficientWeight");
        require(weight <= offer.maxWeight, "ExcessiveWeight");
        (uint256 loanBalance,) = ILoanMinimalOpsOF(MarketStorage.configLayout().loan).getLoanDetails(tokenId);
        require(loanBalance <= offer.debtTolerance, "InsufficientDebtTolerance");
        IVotingEscrowMinimalOpsOF.LockedBalance memory lockedBalance = IVotingEscrowMinimalOpsOF(MarketStorage.configLayout().votingEscrow).locked(tokenId);
        require(lockedBalance.end <= offer.maxLockTime, "ExcessiveLockTime");
    }
}


