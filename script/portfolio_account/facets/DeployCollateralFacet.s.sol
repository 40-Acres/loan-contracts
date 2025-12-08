// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";

contract DeployCollateralFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        CollateralFacet facet = new CollateralFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, VOTING_ESCROW);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "CollateralFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig, address votingEscrow) external {
        CollateralFacet newFacet = new CollateralFacet(portfolioFactory, portfolioAccountConfig, votingEscrow);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "CollateralFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = CollateralFacet.addCollateral.selector;
        selectors[1] = CollateralFacet.getTotalLockedCollateral.selector;
        selectors[2] = CollateralFacet.getTotalDebt.selector;
        selectors[3] = CollateralFacet.getUnpaidFees.selector;
        selectors[4] = CollateralFacet.getMaxLoan.selector;
        selectors[5] = CollateralFacet.getOriginTimestamp.selector;
        selectors[6] = CollateralFacet.removeCollateral.selector;
        selectors[7] = CollateralFacet.getCollateralToken.selector;
        return selectors;
    }
}

