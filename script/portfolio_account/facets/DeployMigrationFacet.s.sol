// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {MigrationFacet} from "../../../src/facets/account/migration/MigrationFacet.sol";
import {IMigrationFacet} from "../../../src/facets/account/migration/IMigrationFacet.sol";

contract DeployMigrationFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        MigrationFacet facet = new MigrationFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, VOTING_ESCROW);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "MigrationFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig, address votingEscrow) external {
        MigrationFacet newFacet = new MigrationFacet(portfolioFactory, portfolioAccountConfig, votingEscrow);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "MigrationFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IMigrationFacet.migrate.selector;
        return selectors;
    }
}

