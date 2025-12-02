// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";

contract DeployLendingFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");
        address LOAN_CONFIG = vm.envAddress("LOAN_CONFIG");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        LendingFacet facet = new LendingFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, LOAN_CONFIG);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "LendingFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig, address loanConfig) external {
        LendingFacet newFacet = new LendingFacet(portfolioFactory, portfolioAccountConfig, loanConfig);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "LendingFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = LendingFacet.borrow.selector;
        selectors[1] = LendingFacet.pay.selector;
        return selectors;
    }
}

