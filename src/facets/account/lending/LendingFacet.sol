// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILoan} from "../../../interfaces/ILoan.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {UserLendingConfig} from "./UserLendingConfig.sol";
import {CollateralFacet} from "../collateral/CollateralFacet.sol";

/**
 * @title LendingFacet
 * @dev Facet for borrowing against collateral in portfolio accounts.
 *      Global debt tracked via CollateralManager, per-loan details from loan contract.
 */
contract LendingFacet is AccessControl {
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    IERC20 public immutable _lendingToken;

    error NotOwnerOfToken();
    error NotPortfolioOwner();

    constructor(address portfolioFactory, address portfolioAccountConfig, address lendingToken) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _lendingToken = IERC20(lendingToken);
    }

    function borrow(uint256 amount) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        CollateralManager.increaseTotalDebt(address(_portfolioAccountConfig), amount);
    }

    function pay(uint256 amount) public  {
        // if the caller is the portfolio manager, use the portfolio owner as the from address, otherwise use the caller
        address from = msg.sender == address(_portfolioFactory.portfolioManager()) ? _portfolioFactory.ownerOf(address(this)) : msg.sender;

        // transfer the funds from the from address to the portfolio account then pay the loan
        IERC20(address(_lendingToken)).transferFrom(from, address(this), amount);
        IERC20(address(_lendingToken)).approve(address(_portfolioAccountConfig.getLoanContract()), amount);
        CollateralManager.decreaseTotalDebt(address(_portfolioAccountConfig), amount);
        IERC20(address(_lendingToken)).approve(address(_portfolioAccountConfig.getLoanContract()), 0);
    }

    function setTopUp(bool topUpEnabled) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserLendingConfig.setTopUp(topUpEnabled);
    }

    function topUp() public {
        bool topUpEnabled = UserLendingConfig.getTopUp();
        if(!topUpEnabled) {
            return;
        }
        (uint256 maxLoan, ) = CollateralFacet(address(this)).getMaxLoan();
        if(maxLoan == 0) {
            return;
        }
        CollateralManager.increaseTotalDebt(address(_portfolioAccountConfig), maxLoan);
    }
}