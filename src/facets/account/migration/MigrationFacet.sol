// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILoan} from "../../../interfaces/ILoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IVoteModule} from "../../../interfaces/IVoteModule.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {PortfolioFactoryConfig} from "../config/PortfolioFactoryConfig.sol";


/**
 * @title MigrationFacet
 */
contract MigrationFacet {
    PortfolioFactory public immutable _portfolioFactory;
    IVotingEscrow public immutable _ve;


    constructor(address portfolioFactory, address ve) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _ve = IVotingEscrow(ve);
    }

    function migrate(uint256 tokenId, uint256 unpaidFees) external onlyLoanContract() {
        require(unpaidFees == 0);
        IVotingEscrow(address(_ve)).transferFrom(msg.sender, address(this), tokenId);
        _migrateLockedCollateral(tokenId);

        (uint256 balance, address borrower) = ILoan(_portfolioFactory.portfolioFactoryConfig().getLoanContract()).getLoanDetails(tokenId);
        require(borrower == _portfolioFactory.ownerOf(address(this)));

        _migrateDebt(balance, unpaidFees);
    }

    function _migrateLockedCollateral(uint256 tokenId) internal virtual {
        CollateralManager.migrateLockedCollateral(address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_ve));
    }

    function _migrateDebt(uint256 balance, uint256 unpaidFees) internal virtual {
        CollateralManager.migrateDebt(address(_portfolioFactory.portfolioFactoryConfig()), balance, unpaidFees);
    }

    modifier onlyLoanContract() {
        require(msg.sender == _portfolioFactory.portfolioFactoryConfig().getLoanContract());
        _;
    }
}