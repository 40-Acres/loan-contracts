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
contract LendingFacet {
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    address public immutable _loanContract;

    error NotOwnerOfToken();

    constructor(address portfolioFactory, address portfolioAccountConfig, address loanContract) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _loanContract = loanContract;
    }

    function borrow(uint256 amount) public {
        CollateralManager.increaseTotalDebt(address(_portfolioAccountConfig), amount);   
    }

    function pay(uint256 amount) public {
        CollateralManager.decreaseTotalDebt(amount);
    }
}