// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";

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
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = BaseCollateralFacet.addCollateral.selector;
        selectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        selectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        selectors[3] = BaseCollateralFacet.getUnpaidFees.selector;
        selectors[4] = BaseCollateralFacet.getMaxLoan.selector;
        selectors[5] = BaseCollateralFacet.getOriginTimestamp.selector;
        selectors[6] = BaseCollateralFacet.removeCollateral.selector;
        selectors[7] = BaseCollateralFacet.removeCollateralTo.selector;
        selectors[8] = BaseCollateralFacet.getCollateralToken.selector;
        selectors[9] = BaseCollateralFacet.getLockedCollateral.selector;
        selectors[10] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        return selectors;
    }
}

