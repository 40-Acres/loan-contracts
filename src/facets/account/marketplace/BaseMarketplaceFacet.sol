// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {AccessControl} from "../utils/AccessControl.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {UserMarketplaceModule} from "./UserMarketplaceModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {IMarketplaceFacet} from "../../../interfaces/IMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../marketplace/PortfolioMarketplace.sol";

/**
 * @title BaseMarketplaceFacet
 * @dev Abstract base for MarketplaceFacet and DynamicMarketplaceFacet.
 *      Stores a local SaleAuthorization and delegates full listing to PortfolioMarketplace.
 *      Concrete subclasses implement the internal dispatchers to route
 *      to either CollateralManager or DynamicCollateralManager.
 */
abstract contract BaseMarketplaceFacet is AccessControl, IMarketplaceFacet {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    IVotingEscrow public immutable _votingEscrow;
    address public immutable _marketplace;

    constructor(address portfolioFactory, address portfolioAccountConfig, address votingEscrow, address marketplace_) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        require(votingEscrow != address(0));
        require(marketplace_ != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _marketplace = marketplace_;
    }

    event SaleProceeded(uint256 indexed tokenId, address indexed buyerPortfolio, uint256 paymentAmount, uint256 debtPaid);

    // ──────────────────────────────────────────────
    // Abstract internal dispatchers
    // ──────────────────────────────────────────────

    function _removeLockedCollateral(uint256 tokenId, address config) internal virtual;
    function _decreaseTotalDebt(address config, uint256 amount) internal virtual returns (uint256 excess);
    function _getRequiredPaymentForCollateralRemoval(address config, uint256 tokenId) internal view virtual returns (uint256);
    function _enforceCollateralRequirements() internal view virtual returns (bool);
    function _getTotalDebt() internal view virtual returns (uint256);
    function _getLockedCollateral(uint256 tokenId) internal view virtual returns (uint256);
    function _getOriginTimestamp(uint256 tokenId) internal view virtual returns (uint256);

    /**
     * @dev Hook to sync debt state before reading it.
     *      DynamicMarketplaceFacet overrides this to call settleRewards() on the
     *      DynamicFeesVault so that vested borrower rewards are applied to debt
     *      before requiredPayment is computed.
     */
    function _syncDebtState() internal virtual {}

    // ──────────────────────────────────────────────
    // Public view functions
    // ──────────────────────────────────────────────

    function marketplace() external view returns (address) {
        return _marketplace;
    }

    function getSaleAuthorization(uint256 tokenId) external view returns (uint256 price, address paymentToken) {
        UserMarketplaceModule.SaleAuthorization memory auth = UserMarketplaceModule.getSaleAuthorization(tokenId);
        return (auth.price, auth.paymentToken);
    }

    function hasSaleAuthorization(uint256 tokenId) external view returns (bool) {
        return UserMarketplaceModule.hasSaleAuthorization(tokenId);
    }

    /**
     * @notice Check if a listing is currently purchasable given the seller's debt state.
     *         Seller debt may increase after listing creation, making the net sale proceeds
     *         insufficient to cover the required debt payment for collateral removal.
     * @param tokenId The token ID of the listing
     * @return purchasable True if the listing can be purchased without reverting
     * @return requiredPayment The debt payment needed to safely remove the collateral
     * @return netPayment The net payment seller receives (listing price minus protocol fee)
     */
    function isListingPurchasable(uint256 tokenId) external view returns (bool purchasable, uint256 requiredPayment, uint256 netPayment) {
        // Check local sale authorization exists
        if (!UserMarketplaceModule.hasSaleAuthorization(tokenId)) {
            return (false, 0, 0);
        }

        // Check centralized listing exists and is not expired
        PortfolioMarketplace.Listing memory listing = PortfolioMarketplace(_marketplace).getListing(tokenId);
        if (listing.owner != address(this)) {
            return (false, 0, 0);
        }
        if (listing.expiresAt > 0 && listing.expiresAt <= block.timestamp) {
            return (false, 0, 0);
        }

        // Calculate net payment after protocol fee
        uint256 feeBps = PortfolioMarketplace(_marketplace).protocolFeeBps();
        netPayment = listing.price - (listing.price * feeBps) / 10000;

        // Get current required payment (reflects current debt state, not listing-time state)
        requiredPayment = _getRequiredPaymentForCollateralRemoval(address(_portfolioAccountConfig), tokenId);

        purchasable = netPayment >= requiredPayment;
    }

    // ──────────────────────────────────────────────
    // Listing Management (via PortfolioManager multicall)
    // ──────────────────────────────────────────────

    /**
     * @notice Create a listing: stores local SaleAuthorization + creates centralized listing
     */
    uint256 public constant MIN_LISTING_PRICE = 10000;

    function makeListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt,
        address allowedBuyer
    ) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(price >= MIN_LISTING_PRICE, "Price below minimum");
        require(_getLockedCollateral(tokenId) > 0, "Token not locked");
        require(_getOriginTimestamp(tokenId) > 0, "Token not originated");

        // Ensure no existing sale authorization
        require(!UserMarketplaceModule.hasSaleAuthorization(tokenId), "Listing already exists");

        // Validate that net payment (after protocol fee) covers required debt payment
        uint256 requiredPayment = _getRequiredPaymentForCollateralRemoval(address(_portfolioAccountConfig), tokenId);
        if (requiredPayment > 0) {
            uint256 feeBps = PortfolioMarketplace(_marketplace).protocolFee();
            uint256 netPayment = price - (price * feeBps) / 10000;
            require(netPayment >= requiredPayment, "Price too low to cover debt after fees");
        }

        // Store local sale authorization
        UserMarketplaceModule.createSaleAuthorization(tokenId, price, paymentToken);

        // Create centralized listing in PortfolioMarketplace
        PortfolioMarketplace(_marketplace).createListing(tokenId, price, paymentToken, expiresAt, allowedBuyer);
    }

    /**
     * @notice Cancel a listing: removes local authorization + cancels centralized listing.
     */
    function cancelListing(uint256 tokenId) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserMarketplaceModule.removeSaleAuthorization(tokenId);
        // Only cancel centralized listing if it still belongs to this portfolio
        PortfolioMarketplace.Listing memory listing = PortfolioMarketplace(_marketplace).getListing(tokenId);
        if (listing.owner == address(this)) {
            PortfolioMarketplace(_marketplace).cancelListing(tokenId);
        }
    }

    // ──────────────────────────────────────────────
    // Expired Listing Cleanup (called by PortfolioMarketplace)
    // ──────────────────────────────────────────────

    /**
     * @notice Called by PortfolioMarketplace when an expired listing is cleaned,
     *         so the local SaleAuthorization is removed in sync.
     */
    function clearExpiredSaleAuthorization(uint256 tokenId) external {
        require(msg.sender == _marketplace, "Not marketplace");
        if (UserMarketplaceModule.hasSaleAuthorization(tokenId)) {
            UserMarketplaceModule.removeSaleAuthorization(tokenId);
        }
    }

    // ──────────────────────────────────────────────
    // Sale Proceeds (called by PortfolioMarketplace)
    // ──────────────────────────────────────────────

    /**
     * @notice Called by PortfolioMarketplace to deliver sale proceeds and transfer the NFT.
     *         Pays only enough debt to stay in good collateral standing, then sends the
     *         rest to the portfolio owner.
     * @param tokenId The veNFT being sold
     * @param buyerPortfolio The buyer's portfolio account
     * @param paymentAmount The net amount (after protocol fee)
     */
    function receiveSaleProceeds(
        uint256 tokenId,
        address buyerPortfolio,
        uint256 paymentAmount
    ) external {
        require(msg.sender == _marketplace, "Not marketplace");
        require(UserMarketplaceModule.hasSaleAuthorization(tokenId), "No sale authorization");

        UserMarketplaceModule.SaleAuthorization memory auth = UserMarketplaceModule.getSaleAuthorization(tokenId);

        UserMarketplaceModule.removeSaleAuthorization(tokenId);

        // Pull funds from marketplace
        IERC20(auth.paymentToken).safeTransferFrom(msg.sender, address(this), paymentAmount);

        address configAddress = address(_portfolioAccountConfig);
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        uint256 debtPaid = 0;

        // Settle any vested rewards before reading debt so requiredPayment
        // reflects the true post-settlement balance, not stale-high pre-settlement debt.
        _syncDebtState();

        // Pay only enough debt to stay in good standing after NFT removal
        uint256 totalDebt = _getTotalDebt();
        if (totalDebt > 0) {
            uint256 requiredPayment = _getRequiredPaymentForCollateralRemoval(configAddress, tokenId);
            if (requiredPayment > 0) {
                uint256 debtPayment = requiredPayment > paymentAmount ? paymentAmount : requiredPayment;
                uint256 excess = _decreaseTotalDebt(configAddress, debtPayment);
                debtPaid = debtPayment - excess;
            }
        }

        // Remove collateral from this portfolio
        _removeLockedCollateral(tokenId, configAddress);


        // Enforce collateral requirements on seller after collateral removal
        _enforceCollateralRequirements();

        // Transfer NFT to buyer portfolio
        _votingEscrow.safeTransferFrom(address(this), buyerPortfolio, tokenId);
        
        // Send remaining USDC to portfolio owner
        uint256 remaining = paymentAmount - debtPaid;
        if (remaining > 0) {
            IERC20(auth.paymentToken).safeTransfer(portfolioOwner, remaining);
        }

        emit SaleProceeded(tokenId, buyerPortfolio, paymentAmount, debtPaid);
    }

}
