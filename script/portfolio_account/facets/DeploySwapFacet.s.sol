// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {SwapFacet} from "../../../src/facets/account/swap/SwapFacet.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";

/**
 * @title DeploySwapFacet
 * @dev Deploy SwapFacet contract
 */
contract DeploySwapFacet is AccountFacetsDeploy {

    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");
        address SWAP_CONFIG = vm.envAddress("SWAP_CONFIG");
        
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        SwapFacet newFacet = new SwapFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, SWAP_CONFIG);
        
        registerFacet(PORTFOLIO_FACTORY, address(newFacet), getSelectorsForFacet(), "SwapFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig, address swapConfig) external {
        SwapFacet newFacet = new SwapFacet(portfolioFactory, portfolioAccountConfig, swapConfig);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "SwapFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = SwapFacet.swap.selector;
        selectors[1] = SwapFacet.userSwap.selector;
        return selectors;
    }
}

