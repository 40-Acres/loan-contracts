// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {DynamicERC4626ClaimingFacet} from "../../../src/facets/account/erc4626/DynamicERC4626ClaimingFacet.sol";

/**
 * @title DeployDynamicERC4626ClaimingFacet
 * @dev Deploy DynamicERC4626ClaimingFacet for vault yield claiming on a
 *      live-debt-read lending pool.
 */
contract DeployDynamicERC4626ClaimingFacet is AccountFacetsDeploy {

    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address VAULT = vm.envAddress("VAULT");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        DynamicERC4626ClaimingFacet facet = new DynamicERC4626ClaimingFacet(PORTFOLIO_FACTORY, VAULT);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "DynamicERC4626ClaimingFacet", false);

        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address vault) external returns (DynamicERC4626ClaimingFacet) {
        DynamicERC4626ClaimingFacet facet = new DynamicERC4626ClaimingFacet(portfolioFactory, vault);
        registerFacet(portfolioFactory, address(facet), getSelectorsForFacet(), "DynamicERC4626ClaimingFacet", true);
        return facet;
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = DynamicERC4626ClaimingFacet.claimVaultYield.selector;
        selectors[1] = DynamicERC4626ClaimingFacet.getAvailableYield.selector;
        selectors[2] = DynamicERC4626ClaimingFacet.getDepositInfo.selector;
        return selectors;
    }
}
