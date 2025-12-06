// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILoan} from "../../../interfaces/ILoan.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";

/**
 * @title LendingFacet
 * @dev Facet for borrowing against collateral in portfolio accounts.
 *      Global debt tracked via CollateralManager, per-loan details from loan contract.
 */
contract LendingFacet is AccessControl {
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;

    error NotOwnerOfToken();
    error NotPortfolioOwner();

    constructor(address portfolioFactory, address portfolioAccountConfig) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
    }

    function borrow(uint256 amount) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        CollateralManager.increaseTotalDebt(address(_portfolioAccountConfig), amount);
    }

    function pay(uint256 tokenId, uint256 amount) public onlyPortfolioManagerMulticall(_portfolioFactory) {
        CollateralManager.decreaseTotalDebt(address(_portfolioAccountConfig), amount);
    }
}