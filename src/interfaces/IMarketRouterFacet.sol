// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {RouteLib} from "../libraries/RouteLib.sol";

interface IMarketRouterFacet {
    function quoteToken(
        RouteLib.BuyRoute route,
        bytes32 marketKey,
        uint256 tokenId,
        bytes calldata quoteData
    ) external view returns (uint256 price, uint256 marketFee, uint256 total, address currency);

    function buyToken(
        RouteLib.BuyRoute route,
        bytes32 marketKey,
        uint256 tokenId,
        uint256 maxTotal,
        bytes calldata buyData,
        bytes calldata optionalPermit2
    ) external;
}


