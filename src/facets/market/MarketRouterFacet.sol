// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {MarketLogicLib} from "../../libraries/MarketLogicLib.sol";
import {RouteLib} from "../../libraries/RouteLib.sol";
import {IMarketRouterFacet} from "../../interfaces/IMarketRouterFacet.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketListingsWalletFacet} from "../../interfaces/IMarketListingsWalletFacet.sol";
import {IMarketListingsLoanFacet} from "../../interfaces/IMarketListingsLoanFacet.sol";
import {IVexyAdapterFacet} from "../../interfaces/IVexyAdapterFacet.sol";
import {RevertHelper} from "../../libraries/RevertHelper.sol";
import {Errors} from "../../libraries/Errors.sol";

contract MarketRouterFacet is IMarketRouterFacet {
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

    function quoteToken(
        RouteLib.BuyRoute route,
        bytes32 adapterKey,
        uint256 tokenId,
        bytes calldata quoteData
        ) external view returns (
            uint256 listingPriceInPaymentToken,
            uint256 protocolFeeInPaymentToken,
            address paymentToken
        ) {
        if (route == RouteLib.BuyRoute.InternalWallet) {
            (uint256 p,uint256 f,address pay) = _quoteInternalWallet(tokenId);
            return (p,f,pay);
        }
        if (route == RouteLib.BuyRoute.InternalLoan) {
            (uint256 p,uint256 f,address pay) = _quoteInternalLoan(tokenId);
            return (p,f,pay);
        }
        // External adapters quote via adapterKey/quoteData path
        MarketStorage.MarketConfigLayout storage cfg = MarketStorage.configLayout();
        address adapter = cfg.externalAdapter[adapterKey];
        if (adapter == address(0)) revert Errors.UnknownAdapter();

        // Delegatecall into adapter to allow reading diamond storage
        (bool success, bytes memory result) =
            adapter.staticcall(abi.encodeWithSignature("quoteToken(uint256,bytes)", tokenId, quoteData));
        if (!success) {
            RevertHelper.revertWithData(result);
        }
        (uint256 price, , address currency) = abi.decode(result, (uint256, uint256, address));
        uint256 fee = (price * cfg.feeBps[RouteLib.BuyRoute.ExternalAdapter]) / 10000;
        return (price, fee, currency);
    }

    function buyToken(
        RouteLib.BuyRoute route,
        bytes32 adapterKey,
        uint256 tokenId,
        address inputToken,
        uint256 maxTotal,
        bytes calldata buyData,
        bytes calldata optionalPermit2
    ) external onlyWhenNotPaused {
        MarketStorage.MarketConfigLayout storage cfg = MarketStorage.configLayout();

        // Single-veNFT per diamond: no escrow parameter; cfg.votingEscrow is authoritative

        if (route == RouteLib.BuyRoute.InternalWallet) {
            (uint256 price, uint256 fee, address paymentToken) = _quoteInternalWallet(tokenId);
            uint256 total = price; // seller pays fee; total user spend bounded by maxTotal
            if (inputToken == paymentToken) {
                if (total > maxTotal) revert Errors.MaxTotalExceeded();
                IMarketListingsWalletFacet(address(this)).takeWalletListingFor(tokenId, msg.sender, inputToken, 0, bytes(""), optionalPermit2);
            } else {
                if (buyData.length == 0) revert Errors.NoTradeData();
                (uint256 amountIn, bytes memory tradeData) = abi.decode(buyData, (uint256, bytes));
                if (amountIn > maxTotal) revert Errors.MaxTotalExceeded();
                IMarketListingsWalletFacet(address(this)).takeWalletListingFor(tokenId, msg.sender, inputToken, amountIn, tradeData, optionalPermit2);
            }

        } else if (route == RouteLib.BuyRoute.InternalLoan) {
            // Get total cost of listing
            (uint256 total,,) = _quoteInternalLoan(tokenId);
            if (total > maxTotal) revert Errors.MaxTotalExceeded();
            // Route to unified loan entry. If swap needed, buyData must carry (amountIn, tradeData)
            if (buyData.length == 0) {
                // No tradeData path
                IMarketListingsLoanFacet(address(this)).takeLoanListingFor(tokenId, msg.sender, inputToken, 0, bytes(""), optionalPermit2);
            } else {
                (uint256 amountIn, bytes memory tradeData) = abi.decode(buyData, (uint256, bytes));
                if (amountIn > maxTotal) revert Errors.MaxTotalExceeded();
                IMarketListingsLoanFacet(address(this)).takeLoanListingFor(tokenId, msg.sender, inputToken, amountIn, tradeData, optionalPermit2);
            }

        } else if (route == RouteLib.BuyRoute.ExternalAdapter) {
            // Look up adapter for the given key
            address adapter = cfg.externalAdapter[adapterKey];
            if (adapter == address(0)) revert Errors.UnknownAdapter();

            // Delegate call to the associated external adapter facet
            (bool success, bytes memory result) =
                adapter.delegatecall(abi.encodeWithSignature("buyToken(uint256,uint256,bytes,bytes)", tokenId, maxTotal, buyData, optionalPermit2));
            if (!success) {
                RevertHelper.revertWithData(result);
            }
        } else {
            revert Errors.InvalidRoute();
        }
    }

    // internal functions for internal routes
    function _quoteInternalWallet(uint256 tokenId) internal view returns (
        uint256 listingPriceInPaymentToken,
        uint256 protocolFeeInPaymentToken,
        address paymentToken
    ) {
        return IMarketListingsWalletFacet(address(this)).quoteWalletListing(tokenId);
    }

    // Removed; router now calls unified takeWalletListing directly

    function _quoteInternalLoan(uint256 tokenId) internal view returns (
        uint256 listingPriceInPaymentToken,
        uint256 protocolFeeInPaymentToken,
        address paymentToken
    ) {
        (uint256 a,uint256 b,,address d) = IMarketListingsLoanFacet(address(this)).quoteLoanListing(tokenId, address(0));
        return (a,b,d);
    }

    // Removed legacy internal helper; router now calls takeLoanListingFor directly
}


