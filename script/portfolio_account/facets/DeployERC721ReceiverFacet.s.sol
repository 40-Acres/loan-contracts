// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {ERC721ReceiverFacet} from "../../../src/facets/ERC721ReceiverFacet.sol";

contract DeployERC721ReceiverFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        ERC721ReceiverFacet facet = new ERC721ReceiverFacet();
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "ERC721ReceiverFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory) external {
        ERC721ReceiverFacet newFacet = new ERC721ReceiverFacet();
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "ERC721ReceiverFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ERC721ReceiverFacet.onERC721Received.selector;
        return selectors;
    }
}

