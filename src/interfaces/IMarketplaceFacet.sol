// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title IMarketplaceFacet
 * @dev Interface for marketplace operations on portfolio accounts.
 *      Sale authorization is stored locally; full listings live in PortfolioMarketplace.
 */
interface IMarketplaceFacet {
    /**
     * @notice Get sale authorization for a token
     * @param tokenId The token ID
     * @return price The authorized sale price
     * @return paymentToken The payment token address
     */
    function getSaleAuthorization(uint256 tokenId) external view returns (uint256 price, address paymentToken);

    /**
     * @notice Check if a sale authorization exists for a token
     * @param tokenId The token ID
     * @return True if authorization exists (price > 0)
     */
    function hasSaleAuthorization(uint256 tokenId) external view returns (bool);

    /**
     * @notice Called by PortfolioMarketplace to deliver sale proceeds and transfer the NFT
     * @param tokenId The ID of the veNFT being sold
     * @param buyerPortfolio The buyer's portfolio account address
     * @param paymentAmount The net amount being paid (after protocol fee)
     */
    function receiveSaleProceeds(
        uint256 tokenId,
        address buyerPortfolio,
        uint256 paymentAmount
    ) external;

    /**
     * @notice Called by PortfolioMarketplace to clear a stale SaleAuthorization
     *         after the centralized listing has been removed (e.g. expired).
     * @param tokenId The token whose local authorization should be cleared
     */
    function clearExpiredSaleAuthorization(uint256 tokenId) external;

    /**
     * @notice Get the marketplace address
     */
    function marketplace() external view returns (address);
}
