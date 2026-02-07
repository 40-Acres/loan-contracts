// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {CollateralManager} from "../collateral/CollateralManager.sol";
import {BaseCollateralFacet} from "./BaseCollateralFacet.sol";

/**
 * @title CollateralFacet
 */
contract CollateralFacet is BaseCollateralFacet {
    constructor(address portfolioFactory, address portfolioAccountConfig, address votingEscrow)
        BaseCollateralFacet(portfolioFactory, portfolioAccountConfig, votingEscrow) {}

    function _addLockedCollateral(address config, uint256 tokenId, address ve) internal override {
        CollateralManager.addLockedCollateral(config, tokenId, ve);
    }

    function _removeLockedCollateral(uint256 tokenId, address config) internal override {
        CollateralManager.removeLockedCollateral(tokenId, config);
    }

    function _getTotalLockedCollateral() internal view override returns (uint256) {
        return CollateralManager.getTotalLockedCollateral();
    }

    function _getTotalDebt() internal view override returns (uint256) {
        return CollateralManager.getTotalDebt();
    }

    function _getUnpaidFees() internal view override returns (uint256) {
        return CollateralManager.getUnpaidFees();
    }

    function _getMaxLoan() internal view override returns (uint256, uint256) {
        return CollateralManager.getMaxLoan(address(_portfolioAccountConfig));
    }

    function _getOriginTimestamp(uint256 tokenId) internal view override returns (uint256) {
        return CollateralManager.getOriginTimestamp(tokenId);
    }

    function _getLockedCollateral(uint256 tokenId) internal view override returns (uint256) {
        return CollateralManager.getLockedCollateral(tokenId);
    }

    function _enforceCollateralRequirements() internal view override returns (bool) {
        return CollateralManager.enforceCollateralRequirements();
    }
}
