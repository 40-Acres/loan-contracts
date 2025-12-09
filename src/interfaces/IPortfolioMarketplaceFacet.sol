// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {RouteLib} from "../libraries/RouteLib.sol";

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
    error InvalidFlashLoanCaller();
    error LBOFailed();
    error InsufficientFunds();

    // ============ Events ============
    event VeNFTSold(uint256 indexed tokenId, address indexed seller, address indexed buyer);
    event CollateralRemoved(uint256 indexed tokenId);
    event LBOExecuted(uint256 indexed tokenId, address indexed buyer, uint256 loanAmount);
    event CollateralAdded(uint256 indexed tokenId, uint256 debtAmount);

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

    // ============ LBO Functions ============

    /**
     * @notice Execute a Leveraged Buyout to purchase a veNFT using flash loan
     * @param tokenId The veNFT to purchase
     * @param route Purchase route
     * @param adapterKey Adapter key for external routes
     * @param inputAsset Asset for purchase
     * @param maxPaymentTotal Max total payment
     * @param userPaymentAsset Asset provided by user
     * @param userPaymentAmount Amount user is contributing
     * @param purchaseTradeData ODOS data for purchase swap
     * @param lboTradeData ODOS data for LBO swap
     * @param marketData Adapter-specific data
     */
    function executeLBO(
        uint256 tokenId,
        RouteLib.BuyRoute route,
        bytes32 adapterKey,
        address inputAsset,
        uint256 maxPaymentTotal,
        address userPaymentAsset,
        uint256 userPaymentAmount,
        bytes calldata purchaseTradeData,
        bytes calldata lboTradeData,
        bytes calldata marketData
    ) external payable;

    /**
     * @notice Flash loan callback for LBO execution
     * @param initiator The portfolio owner who initiated the LBO
     * @param token The flash loaned token
     * @param amount The flash loan amount
     * @param fee The flash loan fee
     * @param data Encoded LBO parameters
     * @return success True if callback succeeded
     */
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bool);

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

