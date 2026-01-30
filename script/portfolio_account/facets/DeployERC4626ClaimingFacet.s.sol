// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {ERC4626ClaimingFacet} from "../../../src/facets/account/claim/ERC4626ClaimingFacet.sol";

/**
 * @title DeployERC4626ClaimingFacet
 * @dev Deploy ERC4626ClaimingFacet contract for vault yield claiming
 */
contract DeployERC4626ClaimingFacet is AccountFacetsDeploy {

    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        ERC4626ClaimingFacet facet = new ERC4626ClaimingFacet(PORTFOLIO_FACTORY);

        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "ERC4626ClaimingFacet", false);

        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory) external returns (ERC4626ClaimingFacet) {
        ERC4626ClaimingFacet facet = new ERC4626ClaimingFacet(portfolioFactory);
        bytes4[] memory selectors = getSelectorsForFacet();
        registerFacet(portfolioFactory, address(facet), selectors, "ERC4626ClaimingFacet", true);
        return facet;
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](6);
        // Share management
        selectors[0] = ERC4626ClaimingFacet.depositShares.selector;
        selectors[1] = ERC4626ClaimingFacet.trackExistingShares.selector;
        selectors[2] = ERC4626ClaimingFacet.withdrawShares.selector;
        // Yield claiming
        selectors[3] = ERC4626ClaimingFacet.claimVaultYield.selector;
        // View functions
        selectors[4] = ERC4626ClaimingFacet.getAvailableYield.selector;
        selectors[5] = ERC4626ClaimingFacet.getDepositInfo.selector;
        return selectors;
    }
}
