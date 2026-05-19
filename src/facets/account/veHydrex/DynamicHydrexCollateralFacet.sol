// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DynamicHydrexCollateralManager} from "./DynamicHydrexCollateralManager.sol";
import {BaseCollateralFacet} from "../collateral/BaseCollateralFacet.sol";

/**
 * @title DynamicHydrexCollateralFacet
 * @dev BaseCollateralFacet variant paired with DynamicFeesVault-backed debt and
 *      Hydrex veHYDX collateral.
 */
contract DynamicHydrexCollateralFacet is BaseCollateralFacet {
    constructor(address portfolioFactory, address votingEscrow)
        BaseCollateralFacet(portfolioFactory, votingEscrow)
    {}

    function _addLockedCollateral(address config, uint256 tokenId, address ve) internal override {
        DynamicHydrexCollateralManager.addLockedCollateral(config, tokenId, ve);
    }

    function _removeLockedCollateral(uint256 tokenId, address config, address ve) internal override {
        DynamicHydrexCollateralManager.removeLockedCollateral(tokenId, config, ve);
    }

    function _getTotalLockedCollateral() internal view override returns (uint256) {
        return DynamicHydrexCollateralManager.getTotalLockedCollateral();
    }

    function _getTotalDebt() internal view override returns (uint256) {
        return DynamicHydrexCollateralManager.getTotalDebt(address(_portfolioFactory.portfolioFactoryConfig()));
    }

    function _getMaxLoan() internal view override returns (uint256, uint256) {
        return DynamicHydrexCollateralManager.getMaxLoan(address(_portfolioFactory.portfolioFactoryConfig()));
    }

    function _getOriginTimestamp(uint256 tokenId) internal view override returns (uint256) {
        return DynamicHydrexCollateralManager.getOriginTimestamp(tokenId);
    }

    function _getLockedCollateral(uint256 tokenId) internal view override returns (uint256) {
        return DynamicHydrexCollateralManager.getLockedCollateral(tokenId);
    }

    function _enforceCollateralRequirements() internal view override returns (bool) {
        return DynamicHydrexCollateralManager.enforceCollateralRequirements();
    }

    function _getLoanUtilization() internal view override returns (uint256) {
        return DynamicHydrexCollateralManager.getLoanUtilization(address(_portfolioFactory.portfolioFactoryConfig()));
    }
}
