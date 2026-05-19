// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {HydrexCollateralManager} from "./HydrexCollateralManager.sol";
import {BaseCollateralFacet} from "../collateral/BaseCollateralFacet.sol";

/**
 * @title HydrexCollateralFacet
 * @dev BaseCollateralFacet variant paired with the simple (non-Dynamic) loan path
 *      and Hydrex veHYDX collateral.
 */
contract HydrexCollateralFacet is BaseCollateralFacet {
    constructor(address portfolioFactory, address votingEscrow)
        BaseCollateralFacet(portfolioFactory, votingEscrow)
    {}

    function _addLockedCollateral(address config, uint256 tokenId, address ve) internal override {
        HydrexCollateralManager.addLockedCollateral(config, tokenId, ve);
    }

    function _removeLockedCollateral(uint256 tokenId, address config, address ve) internal override {
        HydrexCollateralManager.removeLockedCollateral(tokenId, config, ve);
    }

    function _getTotalLockedCollateral() internal view override returns (uint256) {
        return HydrexCollateralManager.getTotalLockedCollateral();
    }

    function _getTotalDebt() internal view override returns (uint256) {
        return HydrexCollateralManager.getTotalDebt();
    }

    function _getMaxLoan() internal view override returns (uint256, uint256) {
        return HydrexCollateralManager.getMaxLoan(address(_portfolioFactory.portfolioFactoryConfig()));
    }

    function _getOriginTimestamp(uint256 tokenId) internal view override returns (uint256) {
        return HydrexCollateralManager.getOriginTimestamp(tokenId);
    }

    function _getLockedCollateral(uint256 tokenId) internal view override returns (uint256) {
        return HydrexCollateralManager.getLockedCollateral(tokenId);
    }

    function _enforceCollateralRequirements() internal view override returns (bool) {
        return HydrexCollateralManager.enforceCollateralRequirements();
    }

    function _getLoanUtilization() internal view override returns (uint256) {
        return HydrexCollateralManager.getLoanUtilization(address(_portfolioFactory.portfolioFactoryConfig()));
    }
}
