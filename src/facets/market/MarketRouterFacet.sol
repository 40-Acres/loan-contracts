// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {MarketLogicLib} from "../../libraries/MarketLogicLib.sol";
import {RouteLib} from "../../libraries/RouteLib.sol";
import {IMarketRouterFacet} from "../../interfaces/IMarketRouterFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketListingsWalletFacet} from "../../interfaces/IMarketListingsWalletFacet.sol";
import {IMarketListingsLoanFacet} from "../../interfaces/IMarketListingsLoanFacet.sol";
import {IVexyAdapterFacet} from "../../interfaces/IVexyAdapterFacet.sol";

contract MarketRouterFacet is IMarketRouterFacet {
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

    function quoteToken(
        RouteLib.BuyRoute route,
        bytes32 marketKey,
        uint256 tokenId,
        bytes calldata quoteData
    ) external view returns (uint256 price, uint256 marketFee, uint256 total, address currency) {
        return (0, 0, 0, address(0));
    }

    function buyToken(
        RouteLib.BuyRoute route,
        bytes32 marketKey,
        uint256 tokenId,
        uint256 maxTotal,
        bytes calldata buyData,
        bytes calldata optionalPermit2
    ) external onlyWhenNotPaused {
        MarketStorage.MarketConfigLayout storage cfg = MarketStorage.configLayout();

        // Single-veNFT per diamond: no escrow parameter; cfg.votingEscrow is authoritative

        if (route == RouteLib.BuyRoute.InternalWallet) {
            // Pre-quote and enforce maxTotal
            (uint256 total,,,) = MarketLogicLib.getTotalCost(tokenId);
            require(total <= maxTotal, "MaxTotalExceeded");
            // Execute wallet listing take via diamond
            IMarketListingsWalletFacet(address(this)).takeWalletListing(tokenId);

        } else if (route == RouteLib.BuyRoute.InternalLoan) {
            // Pre-quote and enforce maxTotal
            (uint256 total,,,) = MarketLogicLib.getTotalCost(tokenId);
            require(total <= maxTotal, "MaxTotalExceeded");
            // Optional debtTolerance provided via buyData
            if (buyData.length >= 32) {
                uint256 debtTolerance = abi.decode(buyData, (uint256));
                IMarketListingsLoanFacet(address(this)).takeLoanListingWithDebt(tokenId, debtTolerance);
            } else {
                IMarketListingsLoanFacet(address(this)).takeLoanListing(tokenId);
            }

        } else if (route == RouteLib.BuyRoute.ExternalAdapter) {
            // Look up adapter for the given key
            address adapter = cfg.externalAdapter[marketKey];
            require(adapter != address(0), "UnknownMarket");
            address marketplace = cfg.externalMarketplace[marketKey];
            require(marketplace != address(0), "UnknownMarketplace");

            // Phase A default encoding: (listingId, expectedCurrency, maxPrice)
            (uint256 listingId, address expectedCurrency, uint256 maxPrice) = abi.decode(
                buyData,
                (uint256, address, uint256)
            );
            // Basic cap: adapter must not exceed the buyer's maxTotal budget
            require(maxPrice <= maxTotal, "MaxTotalExceeded");

            // Route call through the diamond. Selector is mapped to the adapter facet.
            IVexyAdapterFacet(address(this)).buyVexyListing(marketplace, listingId, expectedCurrency, maxPrice);

        } else {
            revert("InvalidRoute");
        }
        // optionalPermit2 is accepted for future use; ignored in Phase A
        optionalPermit2;
    }
}


