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
 *      Concrete subclasses implement the internal dispatchers to route
 *      to either CollateralManager or DynamicCollateralManager.
 */
abstract contract BaseMarketplaceFacet is AccessControl, IMarketplaceFacet {
    using SafeERC20 for IERC20;
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    IVotingEscrow public immutable _votingEscrow;
    address public immutable _marketplace;

    constructor(address portfolioFactory, address portfolioAccountConfig, address votingEscrow, address marketplace) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        require(votingEscrow != address(0));
        require(marketplace != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _marketplace = marketplace;
    }

    event ProtocolFeeTaken(uint256 indexed tokenId, address indexed buyer, uint256 protocolFee);
    event PurchaseFinalized(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 debtAmount, uint256 unpaidFees);
    event DebtTransferredToBuyer(uint256 indexed tokenId, address indexed buyer, uint256 debtAmount, uint256 unpaidFees, address indexed seller);
    event MarketplaceListingBought(uint256 indexed tokenId, address indexed buyer, uint256 price, uint256 debtAttached, address indexed owner);

    // ──────────────────────────────────────────────
    // Abstract internal dispatchers
    // ──────────────────────────────────────────────

    function _addLockedCollateral(address config, uint256 tokenId, address ve) internal virtual;
    function _removeLockedCollateral(uint256 tokenId, address config) internal virtual;
    function _enforceCollateralRequirements() internal view virtual returns (bool);
    function _decreaseTotalDebt(address config, uint256 amount) internal virtual returns (uint256 excess);
    function _addDebt(address config, uint256 amount, uint256 unpaidFees) internal virtual;
    function _transferDebtAway(address config, uint256 amount, uint256 unpaidFees, address buyer) internal virtual;
    function _getRequiredPaymentForCollateralRemoval(address config, uint256 tokenId) internal view virtual returns (uint256);

    // ──────────────────────────────────────────────
    // Public functions
    // ──────────────────────────────────────────────

    function marketplace() external view returns (address) {
        return _marketplace;
    }

    function makeListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 debtAttached,
        uint256 expiresAt,
        address allowedBuyer
    ) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        BaseCollateralFacet collateralFacet = BaseCollateralFacet(address(this));
        require(collateralFacet.getLockedCollateral(tokenId) > 0, "Token not locked");
        require(collateralFacet.getOriginTimestamp(tokenId) > 0, "Token not originated");

        // ensure there is no existing listing for this token
        require(!UserMarketplaceModule.isListingValid(tokenId), "Listing already exists");

        // if user has debt, require the payment token to be the same as the debt token
        if(debtAttached > 0) {
            require(paymentToken == _portfolioAccountConfig.getDebtToken(), "Payment token must be the same as the debt token");
            require(debtAttached <= ICollateralFacet(address(this)).getTotalDebt(), "Debt exceeds actual debt");
        }
        UserMarketplaceModule.createListing(tokenId, price, paymentToken, debtAttached, expiresAt, allowedBuyer);
    }

    function cancelListing(uint256 tokenId) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserMarketplaceModule.removeListing(tokenId);
    }
}
