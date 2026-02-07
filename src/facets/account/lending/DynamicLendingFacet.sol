// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DynamicCollateralManager} from "../collateral/DynamicCollateralManager.sol";
import {BaseLendingFacet} from "./BaseLendingFacet.sol";

/**
 * @title DynamicLendingFacet
 * @dev LendingFacet variant for DynamicFeesVault — delegates to DynamicCollateralManager.
 */
contract DynamicLendingFacet is BaseLendingFacet {
    constructor(address portfolioFactory, address portfolioAccountConfig, address lendingToken)
        BaseLendingFacet(portfolioFactory, portfolioAccountConfig, lendingToken) {}

    function _increaseTotalDebt(address config, uint256 amount) internal override returns (uint256 amountAfterFees, uint256 originationFee) {
        return DynamicCollateralManager.increaseTotalDebt(config, amount);
    }

    function _decreaseTotalDebt(address config, uint256 amount) internal override returns (uint256 excess) {
        return DynamicCollateralManager.decreaseTotalDebt(config, amount);
    }
}
