// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {RouteLib} from "../libraries/RouteLib.sol";

interface IMarketRouterFacet {
    function quoteToken(
        RouteLib.BuyRoute route,
        bytes32 adapterKey,
        uint256 tokenId,
        bytes calldata quoteData
    ) external view returns (
        uint256 listingPriceInPaymentToken,
        uint256 protocolFeeInPaymentToken,
        address paymentToken
    );

    /// @dev A function to buy a token from the market that routes to the appropriate facet to execute the buy
    /// @param route Route type (InternalWallet, InternalLoan, ExternalAdapter)
    /// @param adapterKey Adapter key (ignored for internal routes)
    /// @param tokenId veNFT id
    /// @param inputAsset Asset provided by buyer (address(0) for ETH if supported by route)
    /// @param maxPaymentTotal Upper bound on total spend in payment token (price + fees)
    /// @param maxInputAmount Upper bound on inputAsset amount for swap paths (ignored when no swap)
    /// @param tradeData ODOS calldata for swap (empty when no swap)
    /// @param marketData Adapter-specific payload (ignored for internal routes)
    /// @param optionalPermit2 Optional Permit2 payload to pull funds
    function buyToken(
        RouteLib.BuyRoute route,
        bytes32 adapterKey,
        uint256 tokenId,
        address inputAsset,
        uint256 maxPaymentTotal,
        uint256 maxInputAmount,
        bytes calldata tradeData,
        bytes calldata marketData,
        bytes calldata optionalPermit2
    ) external payable;
}


