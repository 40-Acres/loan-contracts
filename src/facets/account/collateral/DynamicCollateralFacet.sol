// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DynamicCollateralManager} from "../collateral/DynamicCollateralManager.sol";
import {BaseCollateralFacet} from "./BaseCollateralFacet.sol";

/**
 * @title DynamicCollateralFacet
 * @dev CollateralFacet variant for DynamicFeesVault — reads debt from vault instead of local storage.
 */
contract DynamicCollateralFacet is BaseCollateralFacet {
    constructor(address portfolioFactory, address portfolioAccountConfig, address votingEscrow)
        BaseCollateralFacet(portfolioFactory, portfolioAccountConfig, votingEscrow) {}

    function _addLockedCollateral(address config, uint256 tokenId, address ve) internal override {
        DynamicCollateralManager.addLockedCollateral(config, tokenId, ve);
    }

    function _removeLockedCollateral(uint256 tokenId, address config) internal override {
        DynamicCollateralManager.removeLockedCollateral(tokenId, config);
    }

    function _getTotalLockedCollateral() internal view override returns (uint256) {
        return DynamicCollateralManager.getTotalLockedCollateral();
    }

    function _getTotalDebt() internal view override returns (uint256) {
        return DynamicCollateralManager.getTotalDebt(address(_portfolioAccountConfig));
    }

    function _getUnpaidFees() internal pure override returns (uint256) {
        return 0;
    }

    function _getMaxLoan() internal view override returns (uint256, uint256) {
        return DynamicCollateralManager.getMaxLoan(address(_portfolioAccountConfig));
    }

    function _getOriginTimestamp(uint256 tokenId) internal view override returns (uint256) {
        return DynamicCollateralManager.getOriginTimestamp(tokenId);
    }

    function _getLockedCollateral(uint256 tokenId) internal view override returns (uint256) {
        return DynamicCollateralManager.getLockedCollateral(tokenId);
    }

    function _enforceCollateralRequirements() internal view override returns (bool) {
        return DynamicCollateralManager.enforceCollateralRequirements();
    }
}
