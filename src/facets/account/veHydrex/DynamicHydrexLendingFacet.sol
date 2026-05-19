// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DynamicHydrexCollateralManager} from "./DynamicHydrexCollateralManager.sol";
import {BaseLendingFacet} from "../lending/BaseLendingFacet.sol";

/**
 * @title DynamicHydrexLendingFacet
 * @dev BaseLendingFacet variant paired with DynamicFeesVault-backed debt and
 *      Hydrex veHYDX collateral.
 */
contract DynamicHydrexLendingFacet is BaseLendingFacet {
    constructor(address portfolioFactory, address lendingToken) BaseLendingFacet(portfolioFactory, lendingToken) {}

    function _increaseTotalDebt(address config, uint256 amount)
        internal
        override
        returns (uint256 amountAfterFees, uint256 originationFee)
    {
        return DynamicHydrexCollateralManager.increaseTotalDebt(config, amount);
    }

    function _decreaseTotalDebt(address config, uint256 amount) internal override returns (uint256 excess) {
        return DynamicHydrexCollateralManager.decreaseTotalDebt(config, amount);
    }

    function _enforceCollateralRequirements() internal view override {
        DynamicHydrexCollateralManager.enforceCollateralRequirements();
    }
}
