// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {ILoan} from "../../../interfaces/ILoan.sol";
import {IMarketViewFacet} from "../../../interfaces/IMarketViewFacet.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {AccountConfigStorage} from "../../../storage/AccountConfigStorage.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";

/**
 * @title MarketplaceFacet
 * @dev Diamond facet for marketplace operations on portfolio accounts
 * Handles marketplace purchases and offers for veNFTs held by portfolios
 * 
 * This facet is called by the market diamond to finalize purchases,
 * transfers, and update collateral tracking when veNFTs change hands.
 */
contract MarketplaceFacet {
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

    // ============ Immutables ============
    PortfolioFactory public immutable _portfolioFactory;
    AccountConfigStorage public immutable _accountConfigStorage;
    IVotingEscrow public immutable _ve;
    address public immutable _loanContract;
    address public immutable _marketDiamond;

    constructor(
        address portfolioFactory,
        address accountConfigStorage,
        address ve,
        address loanContract,
        address marketDiamond
    ) {
        require(portfolioFactory != address(0));
        require(accountConfigStorage != address(0));
        require(ve != address(0));
        require(loanContract != address(0));
        require(marketDiamond != address(0));
        
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _accountConfigStorage = AccountConfigStorage(accountConfigStorage);
        _ve = IVotingEscrow(ve);
        _loanContract = loanContract;
        _marketDiamond = marketDiamond;
    }

    // ============ Modifiers ============

    modifier onlyMarketDiamond() {
        if (msg.sender != _marketDiamond) revert NotAuthorized();
        _;
    }

    modifier onlyPortfolioOwner() {
        if (msg.sender != _portfolioFactory.ownerOf(address(this))) revert NotPortfolioOwner();
        _;
    }

    // ============ External Functions ============

    /**
     * @notice Finalizes a marketplace direct listing purchase
     * @dev Called by the market diamond after payment is processed
     *      Transfers the veNFT from this portfolio to the buyer
     * @param tokenId The ID of the veNFT being sold
     * @param buyer The address of the buyer (can be EOA or portfolio)
     * @param expectedSeller The expected seller address for validation
     */
    function finalizeMarketPurchase(
        uint256 tokenId,
        address buyer,
        address expectedSeller
    ) external onlyMarketDiamond {
        if (buyer == address(0)) revert ZeroAddress();
        
        // Verify this portfolio is the seller
        if (address(this) != expectedSeller) revert InvalidListing();

        // Verify listing is valid via MarketView facet on the diamond caller
        (address listingOwner, , , , uint256 expiresAt) = IMarketViewFacet(msg.sender).getListing(tokenId);
        if (listingOwner == address(0)) revert InvalidListing();
        if (expiresAt != 0 && block.timestamp >= expiresAt) revert InvalidListing();
        if (listingOwner != address(this)) revert InvalidListing();

        // Verify this portfolio owns the veNFT
        if (_ve.ownerOf(tokenId) != address(this)) revert VeNFTNotInPortfolio();

        // Check loan balance is zero (loan should be paid off before transfer)
        (uint256 balance,) = ILoan(_loanContract).getLoanDetails(tokenId);
        if (balance != 0) revert LoanNotPaidOff();

        // Remove collateral tracking from this portfolio
        CollateralManager.removeLockedColleratal(tokenId, address(_accountConfigStorage));
        
        // Transfer veNFT to buyer
        _ve.transferFrom(address(this), buyer, tokenId);

        emit VeNFTSold(tokenId, address(this), buyer);
        emit CollateralRemoved(tokenId);
    }

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
    ) external onlyMarketDiamond {
        if (buyer == address(0)) revert ZeroAddress();
        
        // Verify this portfolio is the seller
        if (address(this) != expectedSeller) revert InvalidOffer();

        // Validate the offer is present and active
        (
            address creator,
            ,
            ,
            ,
            ,
            uint256 expiresAt
        ) = IMarketViewFacet(msg.sender).getOffer(offerId);
        if (creator == address(0)) revert InvalidOffer();
        if (creator != buyer) revert InvalidOffer();
        if (expiresAt != 0 && block.timestamp >= expiresAt) revert InvalidOffer();

        // Verify this portfolio owns the veNFT
        if (_ve.ownerOf(tokenId) != address(this)) revert VeNFTNotInPortfolio();

        // Check loan balance is zero
        (uint256 balance,) = ILoan(_loanContract).getLoanDetails(tokenId);
        if (balance != 0) revert LoanNotPaidOff();

        // Remove collateral tracking from this portfolio
        CollateralManager.removeLockedColleratal(tokenId, address(_accountConfigStorage));
        
        // Transfer veNFT to buyer
        _ve.transferFrom(address(this), buyer, tokenId);

        emit VeNFTSold(tokenId, address(this), buyer);
        emit CollateralRemoved(tokenId);
    }

    /**
     * @notice Finalizes a Leveraged Buyout (LBO) purchase
     * @dev Called by the market diamond after flash loan is used to purchase
     *      In LBO, the market diamond temporarily becomes the borrower, then transfers to buyer
     * @param tokenId The ID of the veNFT being purchased via LBO
     * @param buyer The final buyer address
     */
    function finalizeLBOPurchase(
        uint256 tokenId,
        address buyer
    ) external onlyMarketDiamond {
        if (buyer == address(0)) revert ZeroAddress();
        
        // In LBO flow, the market diamond should be the current holder
        // This function is called to transfer from market diamond to buyer's portfolio
        // The veNFT should already be with the market diamond at this point
        
        // Verify this portfolio is meant to receive the NFT (buyer should be portfolio owner)
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        if (portfolioOwner != buyer) revert Unauthorized();

        // Transfer veNFT from market diamond to this portfolio
        _ve.transferFrom(msg.sender, address(this), tokenId);
        
        // Add collateral tracking to this portfolio
        CollateralManager.addLockedColleratal(tokenId, address(_ve));

        // Get the loan balance and add to debt tracking
        (uint256 balance,) = ILoan(_loanContract).getLoanDetails(tokenId);
        if (balance > 0) {
            CollateralManager.increaseTotalDebt(address(_accountConfigStorage), balance);
        }

        emit VeNFTSold(tokenId, msg.sender, address(this));
    }

    /**
     * @notice Receive a veNFT into this portfolio from a marketplace purchase
     * @dev Called after buying a veNFT to add it to collateral tracking
     * @param tokenId The ID of the veNFT received
     */
    function receiveMarketPurchase(uint256 tokenId) external onlyMarketDiamond {
        // Verify this portfolio now owns the veNFT
        if (_ve.ownerOf(tokenId) != address(this)) revert VeNFTNotInPortfolio();
        
        // Add collateral tracking
        CollateralManager.addLockedColleratal(tokenId, address(_ve));

        // Check if there's associated debt
        (uint256 balance,) = ILoan(_loanContract).getLoanDetails(tokenId);
        if (balance > 0) {
            CollateralManager.increaseTotalDebt(address(_accountConfigStorage), balance);
        }
    }

    // ============ View Functions ============

    /**
     * @notice Get the portfolio owner
     * @return The address of the portfolio owner
     */
    function getPortfolioOwner() external view returns (address) {
        return _portfolioFactory.ownerOf(address(this));
    }

    /**
     * @notice Check if this portfolio owns a specific veNFT
     * @param tokenId The token ID to check
     * @return True if this portfolio owns the veNFT
     */
    function ownsVeNFT(uint256 tokenId) external view returns (bool) {
        return _ve.ownerOf(tokenId) == address(this);
    }
}
