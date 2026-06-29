// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {DynamicERC4626CollateralFacet} from "../../../src/facets/account/erc4626/DynamicERC4626CollateralFacet.sol";

/**
 * @title DeployDynamicERC4626CollateralFacet
 * @dev Deploy DynamicERC4626CollateralFacet for vault-share collateral on a
 *      live-debt-read lending pool.
 */
contract DeployDynamicERC4626CollateralFacet is AccountFacetsDeploy {

    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address VAULT = vm.envAddress("VAULT");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        DynamicERC4626CollateralFacet facet = new DynamicERC4626CollateralFacet(PORTFOLIO_FACTORY, VAULT);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "DynamicERC4626CollateralFacet", false);

        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address vault) external returns (DynamicERC4626CollateralFacet) {
        DynamicERC4626CollateralFacet facet = new DynamicERC4626CollateralFacet(portfolioFactory, vault);
        registerFacet(portfolioFactory, address(facet), getSelectorsForFacet(), "DynamicERC4626CollateralFacet", true);
        return facet;
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = DynamicERC4626CollateralFacet.addCollateral.selector;
        selectors[1] = DynamicERC4626CollateralFacet.addCollateralFrom.selector;
        selectors[2] = DynamicERC4626CollateralFacet.removeCollateral.selector;
        selectors[3] = DynamicERC4626CollateralFacet.removeCollateralTo.selector;
        selectors[4] = DynamicERC4626CollateralFacet.getTotalLockedCollateral.selector;
        selectors[5] = DynamicERC4626CollateralFacet.getTotalDebt.selector;
        selectors[6] = DynamicERC4626CollateralFacet.getMaxLoan.selector;
        selectors[7] = DynamicERC4626CollateralFacet.enforceCollateralRequirements.selector;
        selectors[8] = DynamicERC4626CollateralFacet.getLoanUtilization.selector;
        selectors[9] = DynamicERC4626CollateralFacet.getCollateralToken.selector;
        selectors[10] = DynamicERC4626CollateralFacet.getCollateral.selector;
        selectors[11] = DynamicERC4626CollateralFacet.getCollateralVault.selector;
        selectors[12] = DynamicERC4626CollateralFacet.getCollateralShares.selector;
        return selectors;
    }
}
