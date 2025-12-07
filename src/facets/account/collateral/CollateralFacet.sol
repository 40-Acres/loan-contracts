// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILoan} from "../../../interfaces/ILoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {CollateralStorage} from "../../../storage/CollateralStorage.sol";
import {IVoteModule} from "../../../interfaces/IVoteModule.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
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

    constructor(address portfolioFactory, address portfolioAccountConfig, address votingEscrow) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _votingEscrow = IVotingEscrow(votingEscrow);
    }

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
        CollateralManager.addLockedCollateral(tokenId, address(_votingEscrow));
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
        address portfolioOwner = _portfolioFactory.ownerOf(address(this));
        IVotingEscrow(address(_votingEscrow)).transferFrom(address(this), portfolioOwner, tokenId);
        CollateralManager.removeLockedCollateral(tokenId, address(_portfolioAccountConfig));
    }

    function getMaxLoan() public view returns (uint256, uint256) {
        return CollateralManager.getMaxLoan(address(_portfolioAccountConfig));
    }
    function getOriginTimestamp(uint256 tokenId) public view returns (uint256) {
        return CollateralManager.getOriginTimestamp(tokenId);
    }
}