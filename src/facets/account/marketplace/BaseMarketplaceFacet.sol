// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {AccessControl} from "../utils/AccessControl.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {UserMarketplaceModule} from "./UserMarketplaceModule.sol";
import {BaseCollateralFacet} from "../collateral/BaseCollateralFacet.sol";
import {ICollateralFacet} from "../collateral/ICollateralFacet.sol";
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

    // ──────────────────────────────────────────────
    // Listing Management (via PortfolioManager multicall)
    // ──────────────────────────────────────────────

    /**
     * @notice Create a listing: stores local SaleAuthorization + creates centralized listing
     */
    function makeListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt,
        address allowedBuyer
    ) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        BaseCollateralFacet collateralFacet = BaseCollateralFacet(address(this));
        require(collateralFacet.getLockedCollateral(tokenId) > 0, "Token not locked");
        require(collateralFacet.getOriginTimestamp(tokenId) > 0, "Token not originated");

        // Ensure no existing sale authorization
        require(!UserMarketplaceModule.hasSaleAuthorization(tokenId), "Listing already exists");

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

        // Pay only enough debt to stay in good standing after NFT removal
        uint256 totalDebt = ICollateralFacet(address(this)).getTotalDebt();
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

        // Transfer NFT to buyer portfolio
        _votingEscrow.transferFrom(address(this), buyerPortfolio, tokenId);

        // Enforce collateral requirements on seller after collateral removal
        ICollateralFacet(address(this)).enforceCollateralRequirements();

        // Send remaining USDC to portfolio owner
        uint256 remaining = paymentAmount - debtPaid;
        if (remaining > 0) {
            IERC20(auth.paymentToken).safeTransfer(portfolioOwner, remaining);
        }

        emit SaleProceeded(tokenId, buyerPortfolio, paymentAmount, debtPaid);
    }

}
