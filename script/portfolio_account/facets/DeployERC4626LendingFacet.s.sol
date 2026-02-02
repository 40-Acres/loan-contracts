// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {ERC4626LendingFacet} from "../../../src/facets/account/erc4626/ERC4626LendingFacet.sol";

/**
 * @title DeployERC4626LendingFacet
 * @dev Deploy ERC4626LendingFacet contract for borrowing against vault share collateral
 */
contract DeployERC4626LendingFacet is AccountFacetsDeploy {

    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");
        address LENDING_TOKEN = vm.envAddress("LENDING_TOKEN");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        ERC4626LendingFacet facet = new ERC4626LendingFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, LENDING_TOKEN);

        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "ERC4626LendingFacet", false);

        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig, address lendingToken) external returns (ERC4626LendingFacet) {
        ERC4626LendingFacet facet = new ERC4626LendingFacet(portfolioFactory, portfolioAccountConfig, lendingToken);
        bytes4[] memory selectors = getSelectorsForFacet();
        registerFacet(portfolioFactory, address(facet), selectors, "ERC4626LendingFacet", true);
        return facet;
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        // Note: getMaxLoan and getTotalDebt are already registered in ERC4626CollateralFacet
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = ERC4626LendingFacet.borrow.selector;
        selectors[1] = ERC4626LendingFacet.pay.selector;
        return selectors;
    }
}
