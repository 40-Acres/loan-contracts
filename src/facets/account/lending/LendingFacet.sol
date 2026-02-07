// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {CollateralManager} from "../collateral/CollateralManager.sol";
import {BaseLendingFacet} from "./BaseLendingFacet.sol";

/**
 * @title LendingFacet
 * @dev Facet for borrowing against collateral in portfolio accounts.
 *      Global debt tracked via CollateralManager
 */
contract LendingFacet is BaseLendingFacet {
    constructor(address portfolioFactory, address portfolioAccountConfig, address lendingToken)
        BaseLendingFacet(portfolioFactory, portfolioAccountConfig, lendingToken) {}

    function _increaseTotalDebt(address config, uint256 amount) internal override returns (uint256 amountAfterFees, uint256 originationFee) {
        return CollateralManager.increaseTotalDebt(config, amount);
    }

    function _decreaseTotalDebt(address config, uint256 amount) internal override returns (uint256 excess) {
        return CollateralManager.decreaseTotalDebt(config, amount);
    }
}
