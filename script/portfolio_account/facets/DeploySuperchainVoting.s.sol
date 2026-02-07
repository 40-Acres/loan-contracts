// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {SuperchainVotingFacet} from "../../../src/facets/account/vote/SuperchainVoting.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";

contract DeploySuperchainVotingFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");
        address VOTING_CONFIG = vm.envAddress("VOTING_CONFIG");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");
        address VOTER = vm.envAddress("VOTER");
        address WETH = vm.envAddress("WETH");
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        SuperchainVotingFacet facet = new SuperchainVotingFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, VOTING_CONFIG, VOTING_ESCROW, VOTER, WETH);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "SuperchainVotingFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig, address votingConfig, address votingEscrow, address voter, address weth) external {
        SuperchainVotingFacet newFacet = new SuperchainVotingFacet(portfolioFactory, portfolioAccountConfig, votingConfig, votingEscrow, voter, weth);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "SuperchainVotingFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = VotingFacet.vote.selector;
        selectors[1] = VotingFacet.voteForLaunchpadToken.selector;
        selectors[2] = VotingFacet.setVotingMode.selector;
        selectors[3] = VotingFacet.isManualVoting.selector;
        selectors[4] = VotingFacet.defaultVote.selector;
        selectors[5] = SuperchainVotingFacet.isSuperchainPool.selector;
        selectors[6] = SuperchainVotingFacet.getMinimumWethBalance.selector;
        return selectors;
    }
}

