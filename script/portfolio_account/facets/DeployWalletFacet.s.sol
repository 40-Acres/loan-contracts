// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {WalletFacet} from "../../../src/facets/account/wallet/WalletFacet.sol";

/**
 * @title DeployWalletFacet
 * @dev Deploy WalletFacet contract
 */
contract DeployWalletFacet is AccountFacetsDeploy {

    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address SWAP_CONFIG = vm.envAddress("SWAP_CONFIG");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        WalletFacet newFacet = new WalletFacet(PORTFOLIO_FACTORY, SWAP_CONFIG);

        registerFacet(PORTFOLIO_FACTORY, address(newFacet), getSelectorsForFacet(), "WalletFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address swapConfig) external {
        WalletFacet newFacet = new WalletFacet(portfolioFactory, swapConfig);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "WalletFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = WalletFacet.transferERC20.selector;
        selectors[1] = WalletFacet.transferNFT.selector;
        selectors[2] = WalletFacet.receiveERC20.selector;
        selectors[3] = WalletFacet.swap.selector;
        selectors[4] = WalletFacet.enforceCollateralRequirements.selector;
        selectors[5] = WalletFacet.onERC721Received.selector;
        return selectors;
    }
}
