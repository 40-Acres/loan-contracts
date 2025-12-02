// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {SwapFacet} from "../../../src/facets/account/swap/SwapFacet.sol";

/**
 * @title DeploySwapFacet
 * @dev Deploy SwapFacet contract
 */
contract DeploySwapFacet is AccountFacetsDeploy {

    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        SwapFacet newFacet = new SwapFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG);
        
        registerFacet(PORTFOLIO_FACTORY, address(newFacet), getSelectorsForFacet(), "SwapFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig) external {
        SwapFacet newFacet = new SwapFacet(portfolioFactory, portfolioAccountConfig);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "SwapFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = SwapFacet.swap.selector;
        return selectors;
    }
}

