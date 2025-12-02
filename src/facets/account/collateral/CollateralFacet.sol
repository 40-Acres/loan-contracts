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



/**
 * @title LoanFacet
 */
contract CollateralFacet {
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

    function addCollateral(uint256 tokenId) public {
        address owner = IVotingEscrow(address(_votingEscrow)).ownerOf(tokenId);
        // token must be in portfolio owners wallet or already in the portfolio account
        require(owner == msg.sender || owner == address(this), NotOwnerOfToken());
        if(owner == msg.sender) {
            // if we have to traansfer, ensure the sender is the owner of the portfolio account
            require(msg.sender == _portfolioFactory.ownerOf(address(this)), NotOwnerOfPortfolioAccount());
            IVotingEscrow(address(_votingEscrow)).transferFrom(msg.sender, address(this), tokenId);
        }
        // add the collateral to the collateral manager
        CollateralManager.addLockedColleratal(tokenId, address(_votingEscrow));
    }


    function getTotalLockedCollateral() public view returns (uint256) {
        return CollateralManager.getTotalLockedColleratal();
    }

    function getTotalDebt() public view returns (uint256) {
        return CollateralManager.getTotalDebt();
    }

    function removeCollateral(uint256 tokenId) public {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)), NotOwnerOfPortfolioAccount());
        IVotingEscrow(address(_votingEscrow)).transferFrom(address(this), msg.sender, tokenId);
        CollateralManager.removeLockedColleratal(tokenId, address(_portfolioAccountConfig));
    }
}