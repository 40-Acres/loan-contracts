// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;
// abstract base class for external market adapters

abstract contract BaseAdapterFacet {
    // @dev This function is called by the MarketRouterFacet to buy a token from the external market
    function buyToken(uint256 tokenId, uint256 maxTotal, bytes calldata buyData, bytes calldata optionalPermit2) external virtual;
    function quoteToken(uint256 tokenId) external view virtual returns (uint256 price, uint256 marketFee, uint256 total, address currency);
}