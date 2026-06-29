// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {DynamicERC4626LendingFacet} from "../../../src/facets/account/erc4626/DynamicERC4626LendingFacet.sol";

/**
 * @title DeployDynamicERC4626LendingFacet
 * @dev Deploy DynamicERC4626LendingFacet for borrowing against vault-share
 *      collateral on a live-debt-read lending pool.
 */
contract DeployDynamicERC4626LendingFacet is AccountFacetsDeploy {

    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address LENDING_TOKEN = vm.envAddress("LENDING_TOKEN");
        address VAULT = vm.envAddress("VAULT");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        DynamicERC4626LendingFacet facet = new DynamicERC4626LendingFacet(PORTFOLIO_FACTORY, LENDING_TOKEN, VAULT);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "DynamicERC4626LendingFacet", false);

        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address lendingToken, address vault) external returns (DynamicERC4626LendingFacet) {
        DynamicERC4626LendingFacet facet = new DynamicERC4626LendingFacet(portfolioFactory, lendingToken, vault);
        registerFacet(portfolioFactory, address(facet), getSelectorsForFacet(), "DynamicERC4626LendingFacet", true);
        return facet;
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        // getMaxLoan and getTotalDebt are already registered in DynamicERC4626CollateralFacet
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = DynamicERC4626LendingFacet.borrow.selector;
        selectors[1] = DynamicERC4626LendingFacet.pay.selector;
        selectors[2] = DynamicERC4626LendingFacet.setTopUp.selector;
        selectors[3] = DynamicERC4626LendingFacet.topUp.selector;
        return selectors;
    }
}
