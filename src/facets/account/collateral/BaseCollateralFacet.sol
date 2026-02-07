// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../accounts/PortfolioManager.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {UserMarketplaceModule} from "../marketplace/UserMarketplaceModule.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {ICollateralFacet} from "./ICollateralFacet.sol";

/**
 * @title BaseCollateralFacet
 * @dev Abstract base for CollateralFacet and DynamicCollateralFacet.
 *      Concrete subclasses implement the internal dispatchers to route
 *      to either CollateralManager or DynamicCollateralManager.
 */
abstract contract BaseCollateralFacet is AccessControl, ICollateralFacet {
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    IVotingEscrow public immutable _votingEscrow;

    error NotOwnerOfToken();
    error NotOwnerOfPortfolioAccount();
    error ListingActive(uint256 tokenId);

    constructor(address portfolioFactory, address portfolioAccountConfig, address votingEscrow) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _votingEscrow = IVotingEscrow(votingEscrow);
    }

    // ──────────────────────────────────────────────
    // Abstract internal dispatchers
    // ──────────────────────────────────────────────

    function _addLockedCollateral(address config, uint256 tokenId, address ve) internal virtual;
    function _removeLockedCollateral(uint256 tokenId, address config) internal virtual;
    function _getTotalLockedCollateral() internal view virtual returns (uint256);
    function _getTotalDebt() internal view virtual returns (uint256);
    function _getUnpaidFees() internal view virtual returns (uint256);
    function _getMaxLoan() internal view virtual returns (uint256, uint256);
    function _getOriginTimestamp(uint256 tokenId) internal view virtual returns (uint256);
    function _getLockedCollateral(uint256 tokenId) internal view virtual returns (uint256);
    function _enforceCollateralRequirements() internal view virtual returns (bool);

    // ──────────────────────────────────────────────
    // Public functions
    // ──────────────────────────────────────────────

    function addCollateral(uint256 tokenId) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        address tokenOwner = IVotingEscrow(address(_votingEscrow)).ownerOf(tokenId);
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        // token must be in portfolio owners wallet or already in the portfolio account
        require(tokenOwner == portfolioOwner || tokenOwner == address(this), NotOwnerOfToken());
        if(tokenOwner == portfolioOwner) {
            // if we have to transfer, transfer from portfolio owner to this portfolio account
            IVotingEscrow(address(_votingEscrow)).transferFrom(portfolioOwner, address(this), tokenId);
        }
        // add the collateral to the collateral manager
        _addLockedCollateral(address(_portfolioAccountConfig), tokenId, address(_votingEscrow));
    }

    function getTotalLockedCollateral() public view returns (uint256) {
        return _getTotalLockedCollateral();
    }

    function getTotalDebt() public view returns (uint256) {
        return _getTotalDebt();
    }

    function getUnpaidFees() public view returns (uint256) {
        return _getUnpaidFees();
    }

    function removeCollateral(uint256 tokenId) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserMarketplaceModule.Listing memory listing = UserMarketplaceModule.getListing(tokenId);
        if (listing.owner != address(0)) {
            revert ListingActive(tokenId);
        }
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        IVotingEscrow(address(_votingEscrow)).transferFrom(address(this), portfolioOwner, tokenId);
        _removeLockedCollateral(tokenId, address(_portfolioAccountConfig));
    }

    function removeCollateralTo(uint256 tokenId, address toPortfolio) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserMarketplaceModule.Listing memory listing = UserMarketplaceModule.getListing(tokenId);
        if (listing.owner != address(0)) {
            revert ListingActive(tokenId);
        }
        // Verify the destination portfolio is owned by the same user
        PortfolioManager manager = PortfolioManager(address(_portfolioFactory.portfolioManager()));
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        address targetFactory = manager.getFactoryForPortfolio(toPortfolio);
        require(targetFactory != address(0), "Target portfolio not registered");
        address targetOwner = PortfolioFactory(targetFactory).ownerOf(toPortfolio);
        require(portfolioOwner == targetOwner, "Must own both portfolios");

        IVotingEscrow(address(_votingEscrow)).transferFrom(address(this), toPortfolio, tokenId);
        _removeLockedCollateral(tokenId, address(_portfolioAccountConfig));
    }

    function getMaxLoan() public view returns (uint256, uint256) {
        return _getMaxLoan();
    }

    function getOriginTimestamp(uint256 tokenId) public view returns (uint256) {
        return _getOriginTimestamp(tokenId);
    }

    function getCollateralToken() public view returns (address tokenAddress) {
        return address(_votingEscrow);
    }

    function getLockedCollateral(uint256 tokenId) public view returns (uint256) {
        return _getLockedCollateral(tokenId);
    }

    function enforceCollateralRequirements() public view returns (bool success) {
        return _enforceCollateralRequirements();
    }
}
