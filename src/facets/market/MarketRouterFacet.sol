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
        address inputToken,
        bytes calldata quoteData
        ) external view returns (
            uint256 listingPriceInPaymentToken,
            uint256 protocolFeeInPaymentToken,
            uint256 requiredInputTokenAmount,
            address paymentToken
        ) {
        if (route == RouteLib.BuyRoute.InternalWallet) {
            return _quoteInternalWallet(tokenId, inputToken);
        }
        if (route == RouteLib.BuyRoute.InternalLoan) {
            return _quoteInternalLoan(tokenId, inputToken);
        }
        // External adapters quote via adapterKey/quoteData path (Phase A stub)
        adapterKey; quoteData; inputToken;
        return (0, 0, 0, address(0));
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
            // Pre-quote and enforce maxTotal
            (uint256 total,,,) = _quoteInternalWallet(tokenId, inputToken);
            // TODO: custom error for max total exceeded
            if (total > maxTotal) revert Errors.MaxTotalExceeded();
            _buyInternalWallet(tokenId, inputToken, optionalPermit2);

        } else if (route == RouteLib.BuyRoute.InternalLoan) {
            // Get total cost of listing
            (uint256 total,,,) = _quoteInternalLoan(tokenId, inputToken);
            // TODO: custom error for max total exceeded
            if (total > maxTotal) revert Errors.MaxTotalExceeded();
            _buyInternalLoan(tokenId, inputToken, optionalPermit2);

        } else if (route == RouteLib.BuyRoute.ExternalAdapter) {
            // Look up adapter for the given key
            address adapter = cfg.externalAdapter[adapterKey];
            if (adapter == address(0)) revert Errors.UnknownAdapter();

            // Delegate call to the associated external adapter facet
            (bool success, bytes memory result) =
                adapter.delegatecall(abi.encodeWithSignature("buyToken(uint256, uint256, bytes, bytes)", tokenId, maxTotal, buyData, optionalPermit2));
            if (!success) {
                RevertHelper.revertWithData(result);
            }
        } else {
            revert Errors.InvalidRoute();
        }
    }

    // internal functions for internal routes
    function _quoteInternalWallet(uint256 tokenId, address inputToken) internal view returns (
        uint256 listingPriceInPaymentToken,
        uint256 protocolFeeInPaymentToken,
        uint256 requiredInputTokenAmount,
        address paymentToken
    ) {
        return IMarketListingsWalletFacet(address(this)).quoteWalletListing(tokenId, inputToken);
    }

    function _buyInternalWallet(uint256 tokenId, address inputToken, bytes calldata optionalPermit2) internal {
        if (inputToken != address(0) && optionalPermit2.length > 0) {
            (IMarketListingsWalletFacet.PermitSingle memory permit, bytes memory sig) =
                abi.decode(optionalPermit2, (IMarketListingsWalletFacet.PermitSingle, bytes));
            IMarketListingsWalletFacet(address(this)).takeWalletListingWithPermit(tokenId, inputToken, permit, sig);
            return;
        }
        IMarketListingsWalletFacet(address(this)).takeWalletListing(tokenId, inputToken);
    }

    function _quoteInternalLoan(uint256 tokenId, address inputToken) internal view returns (
        uint256 listingPriceInPaymentToken,
        uint256 protocolFeeInPaymentToken,
        uint256 requiredInputTokenAmount,
        address paymentToken
    ) {
        return IMarketListingsLoanFacet(address(this)).quoteLoanListing(tokenId, inputToken);
    }

    function _buyInternalLoan(uint256 tokenId, address inputToken, bytes calldata optionalPermit2) internal {
        if (inputToken != address(0) && optionalPermit2.length > 0) {
            (IMarketListingsLoanFacet.PermitSingle memory permit, bytes memory sig) =
                abi.decode(optionalPermit2, (IMarketListingsLoanFacet.PermitSingle, bytes));
            IMarketListingsLoanFacet(address(this)).takeLoanListingWithPermit(tokenId, inputToken, permit, sig);
            return;
        }
        IMarketListingsLoanFacet(address(this)).takeLoanListing(tokenId, inputToken);
    }
}


