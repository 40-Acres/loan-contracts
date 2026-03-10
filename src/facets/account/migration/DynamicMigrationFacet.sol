// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DynamicCollateralManager} from "../collateral/DynamicCollateralManager.sol";
import {MigrationFacet} from "./MigrationFacet.sol";

/**
 * @title DynamicMigrationFacet
 * @dev MigrationFacet variant for DynamicFeesVault — delegates to DynamicCollateralManager.
 */
contract DynamicMigrationFacet is MigrationFacet {
    constructor(
        address portfolioFactory,
        address ve
    ) MigrationFacet(portfolioFactory, ve) {}

    function _migrateLockedCollateral(uint256 tokenId) internal override {
        DynamicCollateralManager.migrateLockedCollateral(address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_ve));
    }

    function _migrateDebt(uint256 balance, uint256 unpaidFees) internal override {
        DynamicCollateralManager.migrateDebt(address(_portfolioFactory.portfolioFactoryConfig()), balance, unpaidFees);
    }
}
