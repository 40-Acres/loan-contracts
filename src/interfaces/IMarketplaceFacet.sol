// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UserMarketplaceModule} from "../facets/account/marketplace/UserMarketplaceModule.sol";

/**
 * @title IMarketplaceFacet
 * @dev Interface for marketplace operations on portfolio accounts
 */
interface IMarketplaceFacet {
    /**
     * @notice Get listing details for a token
     * @param tokenId The token ID
     * @return listing The listing details
     */
    function getListing(uint256 tokenId) external view returns (UserMarketplaceModule.Listing memory);

    /**
     * @notice Processes payment from marketplace, pays down debt if needed, and transfers remaining to seller
     * @dev Called by marketplace after taking funds from buyer
     * @param tokenId The ID of the veNFT being sold
     * @param buyer The address of the buyer
     * @param paymentAmount The amount being paid (should match listing price)
     */
    function processPayment(
        uint256 tokenId,
        address buyer,
        uint256 paymentAmount
    ) external;

    /**
     * @notice Finalize purchase by transferring NFT and debt from seller
     * @param seller The seller's portfolio account address
     * @param tokenId The token ID being purchased
     * @param debtAmount The amount of debt to transfer
     */
    function finalizePurchase(
        address seller,
        uint256 tokenId,
        uint256 debtAmount
    ) external;

    /**
     * @notice Transfer debt away from this portfolio account (seller) to buyer
     * @dev Called by buyer's finalizePurchase to transfer debt
     * @param tokenId The token ID being purchased
     * @param buyer The buyer's portfolio account address
     * @param debtAmount The amount of debt to transfer
     * @param unpaidFees The unpaid fees to transfer
     */
    function transferDebtToBuyer(
        uint256 tokenId,
        address buyer,
        uint256 debtAmount,
        uint256 unpaidFees
    ) external;
}

