// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {RouteLib} from "../../libraries/RouteLib.sol";

// Abstract base for external market adapters routed via MarketRouterFacet
abstract contract BaseAdapterFacet {
    modifier onlyWhenNotPaused() {
        if (MarketStorage.managerPauseLayout().marketPaused) revert("Paused");
        _;
    }

    // Router expects this ABI for external adapters
    function quoteToken(
        uint256 tokenId,
        bytes calldata quoteData
    ) external view virtual returns (
        uint256 listingPriceInPaymentToken,
        uint256 protocolFeeInPaymentToken,
        address paymentToken
    );

    // Uniform adapter ABI used by router for external purchases (separate args; no packing):
    // - tokenId: veNFT id (may be unused by some adapters)
    // - maxPaymentTotal: bound on total spend in payment token (price + fees)
    // - inputAsset: buyer's provided token (address(0) for ETH if supported)
    // - maxInputAmount: bound on inputAsset amount for swap path (ignored for direct path)
    // - tradeData: ODOS calldata for swap; empty for direct-currency path
    // - marketData: adapter-specific payload (e.g., marketplace, listingId, currency, bounds)
    // - optionalPermit2: optional payload to use Permit2
    function buyToken(
        uint256 tokenId,
        uint256 maxPaymentTotal,
        address inputAsset,
        uint256 maxInputAmount,
        bytes calldata tradeData,
        bytes calldata marketData,
        bytes calldata optionalPermit2
    ) external payable virtual;

    // Helpers
    function _externalRouteFeeBps() internal view returns (uint16) {
        return MarketStorage.configLayout().feeBps[RouteLib.BuyRoute.ExternalAdapter];
    }
}