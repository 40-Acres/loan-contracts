// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILoan} from "../../../interfaces/ILoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {CollateralStorage} from "../../../storage/CollateralStorage.sol";
import {IVoteModule} from "../../../interfaces/IVoteModule.sol";
import {AccountConfigStorage} from "../../../storage/AccountConfigStorage.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";  



/**
 * @title MigrationFacet
 */
contract MigrationFacet {
    PortfolioFactory public immutable _portfolioFactory;
    AccountConfigStorage public immutable _accountConfigStorage;
    IVotingEscrow public immutable _ve;
    address public immutable _loanContract;


    constructor(address portfolioFactory, address accountConfigStorage, address ve, address loanContract) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _accountConfigStorage = AccountConfigStorage(accountConfigStorage);
        _loanContract = loanContract;
        _ve = IVotingEscrow(ve);
    }

    function migrate(uint256 tokenId) external onlyLoanContract(msg.sender) {
        IVotingEscrow(address(_ve)).transferFrom(msg.sender, address(this), tokenId);
        CollateralManager.addLockedCollateral(tokenId, address(_ve));

        (uint256 balance, address borrower) = ILoan(_loanContract).getLoanDetails(tokenId);
        require(borrower == _portfolioFactory.ownerOf(address(this)));

        CollateralManager.migrateDebt(address(_accountConfigStorage), balance);
    }

    modifier onlyLoanContract(address loanContract) {
        require(msg.sender == _loanContract);
        _;
    }
}