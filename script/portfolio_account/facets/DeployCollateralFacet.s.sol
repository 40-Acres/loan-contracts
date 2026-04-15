// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";

contract DeployCollateralFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        CollateralFacet facet = new CollateralFacet(PORTFOLIO_FACTORY, VOTING_ESCROW);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "CollateralFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address votingEscrow) external {
        CollateralFacet newFacet = new CollateralFacet(portfolioFactory, votingEscrow);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "CollateralFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = BaseCollateralFacet.addCollateral.selector;
        selectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        selectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        selectors[3] = BaseCollateralFacet.getMaxLoan.selector;
        selectors[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        selectors[5] = BaseCollateralFacet.removeCollateral.selector;
        selectors[6] = BaseCollateralFacet.removeCollateralTo.selector;
        selectors[7] = BaseCollateralFacet.getCollateralToken.selector;
        selectors[8] = BaseCollateralFacet.getLockedCollateral.selector;
        selectors[9] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        selectors[10] = BaseCollateralFacet.getLTVRatio.selector;
        return selectors;
    }
}

