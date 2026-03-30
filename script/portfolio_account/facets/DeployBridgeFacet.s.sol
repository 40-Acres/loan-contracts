// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {BridgeFacet} from "../../../src/facets/account/bridge/BridgeFacet.sol";

/**
 * @title DeployBridgeFacet
 * @dev Deploy BridgeFacet contract
 */
contract DeployBridgeFacet is AccountFacetsDeploy {

    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address USDC = vm.envAddress("USDC");
        address TOKEN_MESSENGER = vm.envAddress("TOKEN_MESSENGER");
        address SWAP_CONFIG = vm.envAddress("SWAP_CONFIG");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        BridgeFacet newFacet = new BridgeFacet(PORTFOLIO_FACTORY, USDC, TOKEN_MESSENGER, 2, SWAP_CONFIG);

        registerFacet(PORTFOLIO_FACTORY, address(newFacet), getSelectorsForFacet(), "BridgeFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address usdc, address tokenMessenger, address swapConfig) external {
        BridgeFacet newFacet = new BridgeFacet(portfolioFactory, usdc, tokenMessenger, 2, swapConfig);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "BridgeFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = BridgeFacet.bridge.selector;
        selectors[1] = BridgeFacet.swapAndBridge.selector;
        return selectors;
    }
}
