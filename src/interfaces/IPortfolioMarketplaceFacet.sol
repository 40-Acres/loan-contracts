// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title IPortfolioMarketplaceFacet
 * @dev Interface for marketplace operations on portfolio accounts
 * This interface is used by the market diamond to finalize purchases
 * when veNFTs are held by portfolio accounts
 */
interface IPortfolioMarketplaceFacet {
    // ============ Errors ============
    error NotAuthorized();
    error ZeroAddress();
    error InvalidListing();
    error InvalidOffer();
    error LoanNotPaidOff();
    error Unauthorized();
    error NotPortfolioOwner();
    error VeNFTNotInPortfolio();

    // ============ Events ============
    event VeNFTSold(uint256 indexed tokenId, address indexed seller, address indexed buyer);
    event CollateralRemoved(uint256 indexed tokenId);

    // ============ External Functions ============

    /**
     * @notice Finalizes a marketplace direct listing purchase
     * @dev Called by the market diamond after payment is processed
     * @param tokenId The ID of the veNFT being sold
     * @param buyer The address of the buyer
     * @param expectedSeller The expected seller address for validation
     */
    function finalizeMarketPurchase(
        uint256 tokenId,
        address buyer,
        address expectedSeller
    ) external;

    /**
     * @notice Finalizes an offer acceptance
     * @dev Called by the market diamond after payment is processed
     * @param tokenId The ID of the veNFT being sold
     * @param buyer The address of the buyer
     * @param expectedSeller The expected seller address for validation
     * @param offerId The ID of the offer being accepted
     */
    function finalizeOfferPurchase(
        uint256 tokenId,
        address buyer,
        address expectedSeller,
        uint256 offerId
    ) external;

    /**
     * @notice Finalizes a Leveraged Buyout (LBO) purchase
     * @dev Called by the market diamond after flash loan is used to purchase
     * @param tokenId The ID of the veNFT being purchased via LBO
     * @param buyer The final buyer address
     */
    function finalizeLBOPurchase(
        uint256 tokenId,
        address buyer
    ) external;

    /**
     * @notice Receive a veNFT into this portfolio from a marketplace purchase
     * @dev Called after buying a veNFT to add it to collateral tracking
     * @param tokenId The ID of the veNFT received
     */
    function receiveMarketPurchase(uint256 tokenId) external;

    // ============ View Functions ============

    /**
     * @notice Get the portfolio owner
     * @return The address of the portfolio owner
     */
    function getPortfolioOwner() external view returns (address);

    /**
     * @notice Check if this portfolio owns a specific veNFT
     * @param tokenId The token ID to check
     * @return True if this portfolio owns the veNFT
     */
    function ownsVeNFT(uint256 tokenId) external view returns (bool);
}

