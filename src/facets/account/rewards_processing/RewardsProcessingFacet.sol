// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {IVoter} from "../../../interfaces/IVoter.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {IRewardsDistributor} from "../../../interfaces/IRewardsDistributor.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILoan} from "../../../interfaces/ILoan.sol";
import {UserRewardsConfig} from "./UserRewardsConfig.sol";
/**
 * @title RewardsProcessingFacet
 * @dev Facet that processes rewards for a portfolio account
 */
contract RewardsProcessingFacet {
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;

    constructor(address portfolioFactory, address portfolioAccountConfig) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
    }

    function processRewards(uint256 rewardsAmount, address asset) external {
        require(_portfolioFactory.portfolioManager().isAuthorizedCaller(msg.sender));
        uint256 totalDebt = CollateralManager.getTotalDebt();
        // if have no debt, process zero balance rewards
        if(totalDebt == 0) {
            _processZeroBalanceRewards(rewardsAmount, asset);
        } else {
            _processActiveLoanRewards(rewardsAmount, asset);
        }
    }

    function _processActiveLoanRewards(uint256 rewardsAmount, address asset) internal {
        require(IERC20(asset).balanceOf(address(this)) >= rewardsAmount);
        address loanContract = _portfolioAccountConfig.getLoanContract();
        require(loanContract != address(0));
        IERC20(asset).approve(loanContract, rewardsAmount);
        ILoan(loanContract).handleActiveLoanPortfolioAccount(rewardsAmount);
    }

    function _processZeroBalanceRewards(uint256 rewardsAmount, address asset) internal {
        address rewardsToken = UserRewardsConfig.getRewardsToken();
        require(rewardsToken != address(0));
        address recipient = UserRewardsConfig.getRecipient();
        require(recipient != address(0));
        IERC20(rewardsToken).transfer(recipient, rewardsAmount);
    }
}

