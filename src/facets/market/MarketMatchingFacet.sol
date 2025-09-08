// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {MarketLogicLib} from "../../libraries/MarketLogicLib.sol";
import {TransferGuardsLib} from "../../libraries/TransferGuardsLib.sol";
import {Errors} from "../../libraries/Errors.sol";
import {IMarketMatchingFacet} from "../../interfaces/IMarketMatchingFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVexyMarketplace} from "../../interfaces/external/IVexyMarketplace.sol";
import {IOpenXSwap} from "../../interfaces/external/IOpenXSwap.sol";
import {IVexyAdapterFacet} from "../../interfaces/IVexyAdapterFacet.sol";
import {IOpenXAdapterFacet} from "../../interfaces/IOpenXAdapterFacet.sol";
import {IMarketListingsWalletFacet} from "../../interfaces/IMarketListingsWalletFacet.sol";
import {IMarketListingsLoanFacet} from "../../interfaces/IMarketListingsLoanFacet.sol";
import {FeeLib} from "../../libraries/FeeLib.sol";
import {Permit2Lib} from "../../libraries/Permit2Lib.sol";
import {RouteLib} from "../../libraries/RouteLib.sol";
import {IMarketListingsWalletFacet} from "../../interfaces/IMarketListingsWalletFacet.sol";
import {IMarketListingsLoanFacet} from "../../interfaces/IMarketListingsLoanFacet.sol";

interface ILoanMinimalOpsMM {
    function getLoanDetails(uint256 tokenId) external view returns (uint256 balance, address borrower);
    function getLoanWeight(uint256 tokenId) external view returns (uint256 weight);
    function setBorrower(uint256 tokenId, address borrower) external;
}

interface IVotingEscrowMinimalOpsMM {
    struct LockedBalance { int128 amount; uint256 end; bool isPermanent; }
    function locked(uint256 _tokenId) external view returns (LockedBalance memory);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

contract MarketMatchingFacet is IMarketMatchingFacet {
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

    function matchOfferWithWalletListing(
        uint256 offerId,
        uint256 tokenId,
        address inputAsset,
        uint256 maxPaymentTotal,
        uint256 maxInputAmount,
        bytes calldata tradeData,
        bytes calldata optionalPermit2
    ) external onlyWhenNotPaused {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        if (offer.creator == address(0)) revert Errors.OfferNotFound();
        if (!MarketLogicLib.isOfferActive(offerId)) revert Errors.OfferExpired();

        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        if (listing.owner == address(0)) revert Errors.ListingNotFound();
        if (!MarketLogicLib.isListingActive(tokenId)) revert Errors.ListingExpired();
        if (listing.allowedBuyer != address(0) && listing.allowedBuyer != offer.creator) revert Errors.NotAllowedBuyer();

        if (listing.hasOutstandingLoan) revert Errors.LoanListingNotAllowed();

        _validateOfferCriteriaWalletOrNoLoan(tokenId, offer);

        // Enforce caller-provided cap (wallet listings: buyer pays listing.price in payment token)
        if (listing.price > maxPaymentTotal) revert Errors.MaxTotalExceeded();

        // Reuse wallet listing settlement with router-style args
        IMarketListingsWalletFacet(address(this)).takeWalletListingFor(
            tokenId,
            offer.creator,
            inputAsset,
            maxInputAmount,
            tradeData,
            optionalPermit2
        );

        delete MarketStorage.orderbookLayout().offers[offerId];
    }

    // Match an internal offer by buying an external Vexy listing and delivering the NFT to the offer creator
    function matchOfferWithVexyListing(
        uint256 offerId,
        address vexy,
        uint256 listingId,
        uint256 maxPrice,
        address inputAsset,
        uint256 maxPaymentTotal,
        uint256 maxInputAmount,
        bytes calldata tradeData,
        bytes calldata optionalPermit2
    ) external onlyWhenNotPaused {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        if (offer.creator == address(0)) revert Errors.OfferNotFound();
        if (!MarketLogicLib.isOfferActive(offerId)) revert Errors.OfferExpired();

        // Read Vexy listing details
        (
            ,
            ,
            address nftCollection,
            uint256 tokenId,
            address currency,
            ,
            ,
            ,
            ,
            uint64 endTime,
            uint64 soldTime
        ) = IVexyMarketplace(vexy).listings(listingId);

        if (nftCollection != MarketStorage.configLayout().votingEscrow) revert Errors.WrongMarketVotingEscrow();
        if (!(soldTime == 0 && endTime >= block.timestamp)) revert Errors.ListingInactive();

        // Validate offer criteria using wallet/no-loan path (Vexy listings are wallet-held)
        _validateOfferCriteriaWalletOrNoLoan(tokenId, offer);

        // Price and currency checks
        uint256 extPrice = IVexyMarketplace(vexy).listingPrice(listingId);
        if (!(extPrice > 0 && extPrice <= maxPrice)) revert Errors.PriceOutOfBounds();
        if (!MarketStorage.configLayout().allowedPaymentToken[currency]) revert Errors.CurrencyNotAllowed();

        // Compute fee on the external price
        uint256 fee = FeeLib.calculateFee(RouteLib.BuyRoute.ExternalAdapter, extPrice);

        // Enforce combined caps
        uint256 totalCost = extPrice + fee;
        if (totalCost > maxPaymentTotal) revert Errors.MaxTotalExceeded();

        // Collect funds from offer.creator (permissionless caller). Use Permit2 if provided; else requires ERC20 approval to diamond.
        if (tradeData.length == 0 && inputAsset == currency) {
            // Direct currency path: pull exact totalCost in currency from offer.creator
            Permit2Lib.permitAndPull(offer.creator, address(this), currency, totalCost, optionalPermit2);
            if (optionalPermit2.length == 0) {
                IERC20(currency).safeTransferFrom(offer.creator, address(this), totalCost);
            }
        } else {
            // Swap path via ODOS from inputAsset to currency
            if (inputAsset == address(0)) revert Errors.NoETHForTokenPayment();
            address odos = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;
            Permit2Lib.permitAndPull(offer.creator, address(this), inputAsset, maxInputAmount, optionalPermit2);
            if (optionalPermit2.length == 0) {
                IERC20(inputAsset).safeTransferFrom(offer.creator, address(this), maxInputAmount);
            }
            IERC20(inputAsset).approve(odos, maxInputAmount);
            (bool success,) = odos.call{value: 0}(tradeData);
            require(success, "ODOS swap failed");
            IERC20(inputAsset).approve(odos, 0);
            if (IERC20(currency).balanceOf(address(this)) < totalCost) revert Errors.Slippage();
        }

        // Settle fee and perform Vexy buy using escrowed currency; call adapter entry with msg.sender == address(this)
        if (fee > 0) {
            IERC20(currency).safeTransfer(FeeLib.feeRecipient(), fee);
        }
        // Call adapter entry via diamond so msg.sender == address(this) inside the adapter
        IVexyAdapterFacet(address(this)).takeVexyListing(vexy, listingId, currency, extPrice);

        // Transfer acquired NFT to the offer creator
        IVotingEscrowMinimalOpsMM(MarketStorage.configLayout().votingEscrow).transferFrom(address(this), offer.creator, tokenId);

        // Finalize: delete internal offer record
        delete MarketStorage.orderbookLayout().offers[offerId];
        emit OfferMatched(offerId, tokenId, offer.creator, extPrice, fee);
    }

    // Match an internal offer by buying an external OpenX listing and delivering the NFT to the offer creator
    function matchOfferWithOpenXListing(
        uint256 offerId,
        address openx,
        uint256 listingId,
        uint256 maxPrice,
        address inputAsset,
        uint256 maxPaymentTotal,
        uint256 maxInputAmount,
        bytes calldata tradeData,
        bytes calldata optionalPermit2
    ) external onlyWhenNotPaused {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        if (offer.creator == address(0)) revert Errors.OfferNotFound();
        if (!MarketLogicLib.isOfferActive(offerId)) revert Errors.OfferExpired();

        // Read OpenX listing details
        (
            address veNft,
            ,
            ,
            uint256 tokenId,
            address currency,
            uint256 price,
            uint256 startTime,
            uint256 endTime,
            uint256 sold
        ) = IOpenXSwap(openx).Listings(listingId);

        if (veNft != MarketStorage.configLayout().votingEscrow) revert Errors.WrongMarketVotingEscrow();
        if (!(sold == 0 && endTime >= block.timestamp && startTime <= block.timestamp)) revert Errors.ListingInactive();

        // Validate offer criteria (wallet/no-loan path)
        _validateOfferCriteriaWalletOrNoLoan(tokenId, offer);

        // Price and currency checks
        if (!(price > 0 && price <= maxPrice)) revert Errors.PriceOutOfBounds();
        if (!MarketStorage.configLayout().allowedPaymentToken[currency]) revert Errors.CurrencyNotAllowed();

        // Compute fee on the external price
        uint256 fee = FeeLib.calculateFee(RouteLib.BuyRoute.ExternalAdapter, price);

        // Enforce combined caps
        uint256 totalCost = price + fee;
        if (totalCost > maxPaymentTotal) revert Errors.MaxTotalExceeded();

        // Collect funds from offer.creator (permissionless caller). Use Permit2 if provided; else requires ERC20 approval to diamond.
        if (tradeData.length == 0 && inputAsset == currency) {
            // Direct currency path: pull exact totalCost in currency from offer.creator
            Permit2Lib.permitAndPull(offer.creator, address(this), currency, totalCost, optionalPermit2);
            if (optionalPermit2.length == 0) {
                IERC20(currency).safeTransferFrom(offer.creator, address(this), totalCost);
            }
        } else {
            // Swap path via ODOS from inputAsset to currency
            if (inputAsset == address(0)) revert Errors.NoETHForTokenPayment();
            address odos = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;
            Permit2Lib.permitAndPull(offer.creator, address(this), inputAsset, maxInputAmount, optionalPermit2);
            if (optionalPermit2.length == 0) {
                IERC20(inputAsset).safeTransferFrom(offer.creator, address(this), maxInputAmount);
            }
            IERC20(inputAsset).approve(odos, maxInputAmount);
            (bool success,) = odos.call{value: 0}(tradeData);
            require(success, "ODOS swap failed");
            IERC20(inputAsset).approve(odos, 0);
            if (IERC20(currency).balanceOf(address(this)) < totalCost) revert Errors.Slippage();
        }

        // Settle fee and perform OpenX buy using escrowed currency; call adapter entry with msg.sender == address(this)
        if (fee > 0) {
            IERC20(currency).safeTransfer(FeeLib.feeRecipient(), fee);
        }
        IOpenXAdapterFacet(address(this)).takeOpenXListing(openx, listingId, currency, price);

        // Transfer acquired NFT to the offer creator
        IVotingEscrowMinimalOpsMM(MarketStorage.configLayout().votingEscrow).transferFrom(address(this), offer.creator, tokenId);

        // Finalize: delete internal offer record
        delete MarketStorage.orderbookLayout().offers[offerId];
        emit OfferMatched(offerId, tokenId, offer.creator, price, fee);
    }

    function matchOfferWithLoanListing(
        uint256 offerId,
        uint256 tokenId,
        address inputAsset,
        uint256 maxPaymentTotal,
        uint256 maxInputAmount,
        bytes calldata tradeData,
        bytes calldata optionalPermit2
    ) external onlyWhenNotPaused {
        MarketStorage.Offer storage offer = MarketStorage.orderbookLayout().offers[offerId];
        if (offer.creator == address(0)) revert Errors.OfferNotFound();
        if (!MarketLogicLib.isOfferActive(offerId)) revert Errors.OfferExpired();

        MarketStorage.Listing storage listing = MarketStorage.orderbookLayout().listings[tokenId];
        if (listing.owner == address(0)) revert Errors.ListingNotFound();
        if (!MarketLogicLib.isListingActive(tokenId)) revert Errors.ListingExpired();
        if (listing.allowedBuyer != address(0) && listing.allowedBuyer != offer.creator) revert Errors.NotAllowedBuyer();
        _validateOfferCriteriaLoan(tokenId, offer);

        // Enforce caller-provided cap based on a quote from the loan facet
        (,, uint256 requiredInputAmount,) = IMarketListingsLoanFacet(address(this)).quoteLoanListing(tokenId, address(0));
        if (requiredInputAmount > maxPaymentTotal) revert Errors.MaxTotalExceeded();

        // Delegate to loan facet so payoff + borrower handoff follow the same invariants and swap path
        IMarketListingsLoanFacet(address(this)).takeLoanListingFor(
            tokenId,
            offer.creator,
            inputAsset,
            maxInputAmount,
            tradeData,
            optionalPermit2
        );

        delete MarketStorage.orderbookLayout().offers[offerId];
    }

    function _validateOfferCriteriaLoan(uint256 tokenId, MarketStorage.Offer storage offer) internal view {
        uint256 weight = ILoanMinimalOpsMM(MarketStorage.configLayout().loan).getLoanWeight(tokenId);
        require(weight >= offer.minWeight, "InsufficientWeight");
        require(weight <= offer.maxWeight, "ExcessiveWeight");
        (uint256 loanBalance,) = ILoanMinimalOpsMM(MarketStorage.configLayout().loan).getLoanDetails(tokenId);
        require(loanBalance <= offer.debtTolerance, "InsufficientDebtTolerance");
        IVotingEscrowMinimalOpsMM.LockedBalance memory lockedBalance = IVotingEscrowMinimalOpsMM(MarketStorage.configLayout().votingEscrow).locked(tokenId);
    }

    function _validateOfferCriteriaWalletOrNoLoan(uint256 tokenId, MarketStorage.Offer storage offer) internal view {
        uint256 weight = MarketLogicLib.getVeNFTWeight(tokenId);
        require(weight >= offer.minWeight, "InsufficientWeight");
        require(weight <= offer.maxWeight, "ExcessiveWeight");
        address loanAddr = MarketStorage.configLayout().loan;
        if (loanAddr != address(0)) {
            (uint256 loanBalance,) = ILoanMinimalOpsMM(loanAddr).getLoanDetails(tokenId);
            require(loanBalance <= offer.debtTolerance, "InsufficientDebtTolerance");
        }
        IVotingEscrowMinimalOpsMM.LockedBalance memory lockedBalance = IVotingEscrowMinimalOpsMM(MarketStorage.configLayout().votingEscrow).locked(tokenId);
    }
}


