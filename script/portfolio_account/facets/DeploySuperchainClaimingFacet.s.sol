// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {SuperchainClaimingFacet} from "../../../src/facets/account/claim/SuperchainClaimingFacet.sol";

/**
 * @title DeploySuperchainClaimingFacet
 * @dev Deploy SuperchainClaimingFacet contract
 */
contract DeploySuperchainClaimingFacet is AccountFacetsDeploy {

    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        SuperchainClaimingFacet facet = new SuperchainClaimingFacet();

        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "SuperchainClaimingFacet", false);

        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory) external returns (SuperchainClaimingFacet) {
        SuperchainClaimingFacet facet = new SuperchainClaimingFacet();
        bytes4[] memory selectors = getSelectorsForFacet();
        registerFacet(portfolioFactory, address(facet), selectors, "SuperchainClaimingFacet", true);
        return facet;
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = SuperchainClaimingFacet.claimSuperchainRewards.selector;
        return selectors;
    }
}
