// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../accounts/PortfolioManager.sol";
import {CollateralStorage} from "../../../storage/CollateralStorage.sol";
import {IVoteModule} from "../../../interfaces/IVoteModule.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {DynamicCollateralManager} from "../collateral/DynamicCollateralManager.sol";
import {UserMarketplaceModule} from "../marketplace/UserMarketplaceModule.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {ICollateralFacet} from "./ICollateralFacet.sol";

/**
 * @title DynamicCollateralFacet
 * @dev CollateralFacet variant for DynamicFeesVault — reads debt from vault instead of local storage.
 */
contract DynamicCollateralFacet is AccessControl, ICollateralFacet {
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

    function addCollateral(uint256 tokenId) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        address tokenOwner = IVotingEscrow(address(_votingEscrow)).ownerOf(tokenId);
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        require(tokenOwner == portfolioOwner || tokenOwner == address(this), NotOwnerOfToken());
        if(tokenOwner == portfolioOwner) {
            IVotingEscrow(address(_votingEscrow)).transferFrom(portfolioOwner, address(this), tokenId);
        }
        DynamicCollateralManager.addLockedCollateral(address(_portfolioAccountConfig), tokenId, address(_votingEscrow));
    }

    function getTotalLockedCollateral() public view returns (uint256) {
        return DynamicCollateralManager.getTotalLockedCollateral();
    }

    function getTotalDebt() public view returns (uint256) {
        return DynamicCollateralManager.getTotalDebt(address(_portfolioAccountConfig));
    }

    function getUnpaidFees() public pure returns (uint256) {
        return 0;
    }

    function removeCollateral(uint256 tokenId) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserMarketplaceModule.Listing memory listing = UserMarketplaceModule.getListing(tokenId);
        if (listing.owner != address(0)) {
            revert ListingActive(tokenId);
        }
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        IVotingEscrow(address(_votingEscrow)).transferFrom(address(this), portfolioOwner, tokenId);
        DynamicCollateralManager.removeLockedCollateral(tokenId, address(_portfolioAccountConfig));
    }

    function removeCollateralTo(uint256 tokenId, address toPortfolio) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserMarketplaceModule.Listing memory listing = UserMarketplaceModule.getListing(tokenId);
        if (listing.owner != address(0)) {
            revert ListingActive(tokenId);
        }
        PortfolioManager manager = PortfolioManager(address(_portfolioFactory.portfolioManager()));
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        address targetFactory = manager.getFactoryForPortfolio(toPortfolio);
        require(targetFactory != address(0), "Target portfolio not registered");
        address targetOwner = PortfolioFactory(targetFactory).ownerOf(toPortfolio);
        require(portfolioOwner == targetOwner, "Must own both portfolios");

        IVotingEscrow(address(_votingEscrow)).transferFrom(address(this), toPortfolio, tokenId);
        DynamicCollateralManager.removeLockedCollateral(tokenId, address(_portfolioAccountConfig));
    }

    function getMaxLoan() public view returns (uint256, uint256) {
        return DynamicCollateralManager.getMaxLoan(address(_portfolioAccountConfig));
    }

    function getOriginTimestamp(uint256 tokenId) public view returns (uint256) {
        return DynamicCollateralManager.getOriginTimestamp(tokenId);
    }

    function getCollateralToken() public view returns (address tokenAddress) {
        return address(_votingEscrow);
    }

    function getLockedCollateral(uint256 tokenId) public view returns (uint256) {
        return DynamicCollateralManager.getLockedCollateral(tokenId);
    }

    function enforceCollateralRequirements() public view returns (bool success) {
        return DynamicCollateralManager.enforceCollateralRequirements();
    }
}
