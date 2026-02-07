// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ICollateralFacet} from "../../src/facets/account/collateral/ICollateralFacet.sol";

/**
 * @title MockCollateralFacet
 * @dev A mock collateral facet that always returns true for enforceCollateralRequirements
 * Used for testing facets that don't directly involve collateral management
 */
contract MockCollateralFacet is ICollateralFacet {
    function getTotalDebt() external pure override returns (uint256) {
        return 0;
    }

    function getUnpaidFees() external pure override returns (uint256) {
        return 0;
    }

    function getMaxLoan() external pure override returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        return (type(uint256).max, type(uint256).max);
    }

    function enforceCollateralRequirements() external pure override returns (bool success) {
        return true;
    }

    function getTotalLockedCollateral() external pure override returns (uint256) {
        return 0;
    }
}
