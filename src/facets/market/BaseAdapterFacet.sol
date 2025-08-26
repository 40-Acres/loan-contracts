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

    function buyToken(
        uint256 tokenId,
        uint256 maxTotal,
        bytes calldata buyData,
        bytes calldata optionalPermit2
    ) external virtual;

    // Helpers
    function _externalRouteFeeBps() internal view returns (uint16) {
        return MarketStorage.configLayout().feeBps[RouteLib.BuyRoute.ExternalAdapter];
    }
}