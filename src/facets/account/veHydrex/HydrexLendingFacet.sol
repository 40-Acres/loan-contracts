// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {HydrexCollateralManager} from "./HydrexCollateralManager.sol";
import {BaseLendingFacet} from "../lending/BaseLendingFacet.sol";

/**
 * @title HydrexLendingFacet
 * @dev BaseLendingFacet variant paired with the simple (non-Dynamic) loan path
 *      and Hydrex veHYDX collateral.
 */
contract HydrexLendingFacet is BaseLendingFacet {
    constructor(address portfolioFactory, address lendingToken) BaseLendingFacet(portfolioFactory, lendingToken) {}

    function _increaseTotalDebt(address config, uint256 amount)
        internal
        override
        returns (uint256 amountAfterFees, uint256 originationFee)
    {
        return HydrexCollateralManager.increaseTotalDebt(config, amount);
    }

    function _decreaseTotalDebt(address config, uint256 amount) internal override returns (uint256 excess) {
        return HydrexCollateralManager.decreaseTotalDebt(config, amount);
    }

    function _enforceCollateralRequirements() internal view override {
        HydrexCollateralManager.enforceCollateralRequirements();
    }
}
