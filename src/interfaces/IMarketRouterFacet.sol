// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {RouteLib} from "../libraries/RouteLib.sol";

interface IMarketRouterFacet {
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
    );

    function buyToken(
        RouteLib.BuyRoute route,
        bytes32 adapterKey,
        uint256 tokenId,
        address inputToken,
        uint256 maxTotal,
        bytes calldata buyData,
        bytes calldata optionalPermit2
    ) external;
}


