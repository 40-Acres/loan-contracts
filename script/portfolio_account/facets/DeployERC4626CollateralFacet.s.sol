// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {ERC4626CollateralFacet} from "../../../src/facets/account/collateral/ERC4626CollateralFacet.sol";

/**
 * @title DeployERC4626CollateralFacet
 * @dev Deploy ERC4626CollateralFacet contract for vault share collateral management
 */
contract DeployERC4626CollateralFacet is AccountFacetsDeploy {

    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        ERC4626CollateralFacet facet = new ERC4626CollateralFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG);

        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "ERC4626CollateralFacet", false);

        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig) external returns (ERC4626CollateralFacet) {
        ERC4626CollateralFacet facet = new ERC4626CollateralFacet(portfolioFactory, portfolioAccountConfig);
        bytes4[] memory selectors = getSelectorsForFacet();
        registerFacet(portfolioFactory, address(facet), selectors, "ERC4626CollateralFacet", true);
        return facet;
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](12);
        // Collateral management
        selectors[0] = ERC4626CollateralFacet.addCollateral.selector;
        selectors[1] = ERC4626CollateralFacet.addCollateralFrom.selector;
        selectors[2] = bytes4(keccak256("removeCollateral(uint256)")); // removeCollateral(uint256 shares)
        selectors[3] = ERC4626CollateralFacet.removeCollateralTo.selector;
        // ICollateralFacet interface
        selectors[4] = ERC4626CollateralFacet.getTotalLockedCollateral.selector;
        selectors[5] = ERC4626CollateralFacet.getTotalDebt.selector;
        selectors[6] = ERC4626CollateralFacet.getUnpaidFees.selector;
        selectors[7] = ERC4626CollateralFacet.getMaxLoan.selector;
        selectors[8] = ERC4626CollateralFacet.enforceCollateralRequirements.selector;
        // ERC4626 specific views
        selectors[9] = ERC4626CollateralFacet.getCollateral.selector;
        selectors[10] = ERC4626CollateralFacet.getCollateralVault.selector;
        selectors[11] = ERC4626CollateralFacet.getCollateralShares.selector;
        return selectors;
    }
}
