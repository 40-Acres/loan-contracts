// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {ClaimingFacet} from "../../../src/facets/account/claim/ClaimingFacet.sol";

/**
 * @title DeployClaimingFacet
 * @dev Deploy ClaimingFacet contract
 */
contract DeployClaimingFacet is AccountFacetsDeploy {

    function run() external {     
        address PORTFOLIO_FACTORY  = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");
        address VOTER = vm.envAddress("VOTER");
        address REWARDS_DISTRIBUTOR = vm.envAddress("REWARDS_DISTRIBUTOR");
        address LOAN_CONFIG = vm.envAddress("LOAN_CONFIG");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        ClaimingFacet facet = new ClaimingFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, VOTING_ESCROW, VOTER, REWARDS_DISTRIBUTOR, LOAN_CONFIG);
        
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "ClaimingFacet", false);
        
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig, address votingEscrow, address voter, address rewardsDistributor, address loanConfig) external returns (ClaimingFacet) {
        
        ClaimingFacet facet = new ClaimingFacet(portfolioFactory, portfolioAccountConfig, votingEscrow, voter, rewardsDistributor, loanConfig);
        bytes4[] memory selectors = getSelectorsForFacet();
        registerFacet(portfolioFactory, address(facet), selectors, "ClaimingFacet", true);
        
        return ClaimingFacet(address(facet));
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = ClaimingFacet.claimFees.selector;
        selectors[1] = ClaimingFacet.claimRebase.selector;
        selectors[2] = ClaimingFacet.claimLaunchpadToken.selector;
        selectors[3] = ClaimingFacet.processRewards.selector;
        return selectors;
    }
}

