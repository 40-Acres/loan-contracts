// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {CollateralManager} from "../collateral/CollateralManager.sol";
import {BaseCollateralFacet} from "./BaseCollateralFacet.sol";

/**
 * @title CollateralFacet
 */
contract CollateralFacet is BaseCollateralFacet {
    constructor(address portfolioFactory, address votingEscrow)
        BaseCollateralFacet(portfolioFactory, votingEscrow) {}

    function _addLockedCollateral(address config, uint256 tokenId, address ve) internal override {
        CollateralManager.addLockedCollateral(config, tokenId, ve);
    }

    function _removeLockedCollateral(uint256 tokenId, address config, address ve) internal override {
        CollateralManager.removeLockedCollateral(tokenId, config, ve);
    }

    function _getTotalLockedCollateral() internal view override returns (uint256) {
        return CollateralManager.getTotalLockedCollateral();
    }

    function _getTotalDebt() internal view override returns (uint256) {
        return CollateralManager.getTotalDebt();
    }

    function _getMaxLoan() internal view override returns (uint256, uint256) {
        return CollateralManager.getMaxLoan(address(_portfolioFactory.portfolioFactoryConfig()));
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

    function _getLTVRatio() internal view override returns (uint256) {
        return CollateralManager.getLTVRatio(address(_portfolioFactory.portfolioFactoryConfig()));
    }
}
