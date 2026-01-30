// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../accounts/PortfolioManager.sol";
import {CollateralStorage} from "../../../storage/CollateralStorage.sol";
import {IVoteModule} from "../../../interfaces/IVoteModule.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {UserMarketplaceModule} from "../marketplace/UserMarketplaceModule.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {ICollateralFacet} from "./ICollateralFacet.sol";
/**
 * @title CollateralFacet
 */
contract CollateralFacet is AccessControl, ICollateralFacet {
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

        // Token must be owned by: portfolio owner's EOA, this portfolio, or another portfolio owned by the same user
        bool isOwnedByPortfolioOwner = tokenOwner == portfolioOwner;
        bool isOwnedByThisPortfolio = tokenOwner == address(this);
        bool isOwnedByAnotherUserPortfolio = false;

        if (!isOwnedByPortfolioOwner && !isOwnedByThisPortfolio) {
            // Check if token is in another portfolio owned by the same user
            PortfolioManager manager = PortfolioManager(address(_portfolioFactory.portfolioManager()));
            address tokenOwnerFactory = manager.getFactoryForPortfolio(tokenOwner);
            if (tokenOwnerFactory != address(0)) {
                address tokenOwnerPortfolioOwner = PortfolioFactory(tokenOwnerFactory).ownerOf(tokenOwner);
                isOwnedByAnotherUserPortfolio = tokenOwnerPortfolioOwner == portfolioOwner;
            }
        }

        require(isOwnedByPortfolioOwner || isOwnedByThisPortfolio || isOwnedByAnotherUserPortfolio, NotOwnerOfToken());

        if(tokenOwner != address(this)) {
            // Transfer from current owner (EOA or another portfolio) to this portfolio account
            IVotingEscrow(address(_votingEscrow)).transferFrom(tokenOwner, address(this), tokenId);
        }
        // add the collateral to the collateral manager
        CollateralManager.addLockedCollateral(address(_portfolioAccountConfig), tokenId, address(_votingEscrow));
    }


    function getTotalLockedCollateral() public view returns (uint256) {
        return CollateralManager.getTotalLockedCollateral();
    }

    function getTotalDebt() public view returns (uint256) {
        return CollateralManager.getTotalDebt();
    }

    function getUnpaidFees() public view returns (uint256) {
        return CollateralManager.getUnpaidFees();
    }

    function removeCollateral(uint256 tokenId) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserMarketplaceModule.Listing memory listing = UserMarketplaceModule.getListing(tokenId);
        if (listing.owner != address(0)) {
            revert ListingActive(tokenId);
        }
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        IVotingEscrow(address(_votingEscrow)).transferFrom(address(this), portfolioOwner, tokenId);
        CollateralManager.removeLockedCollateral(tokenId, address(_portfolioAccountConfig));
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
        CollateralManager.removeLockedCollateral(tokenId, address(_portfolioAccountConfig));
    }

    function getMaxLoan() public view returns (uint256, uint256) {
        return CollateralManager.getMaxLoan(address(_portfolioAccountConfig));
    }
    function getOriginTimestamp(uint256 tokenId) public view returns (uint256) {
        return CollateralManager.getOriginTimestamp(tokenId);
    }

    function getCollateralToken() public view returns (address tokenAddress) {
        return address(_votingEscrow);
    }

    function getLockedCollateral(uint256 tokenId) public view returns (uint256) {
        return CollateralManager.getLockedCollateral(tokenId);
    }

    function enforceCollateralRequirements() public view returns (bool success) {
        return CollateralManager.enforceCollateralRequirements();
    }
}