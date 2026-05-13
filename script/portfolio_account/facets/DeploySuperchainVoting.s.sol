// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {SuperchainVotingFacet} from "../../../src/facets/account/vote/SuperchainVoting.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";

contract DeploySuperchainVotingFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address VOTING_CONFIG = vm.envAddress("VOTING_CONFIG");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");
        address VOTER = vm.envAddress("VOTER");
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        SuperchainVotingFacet facet = new SuperchainVotingFacet(PORTFOLIO_FACTORY, VOTING_CONFIG, VOTING_ESCROW, VOTER);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "SuperchainVotingFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address votingConfig, address votingEscrow, address voter) external {
        SuperchainVotingFacet newFacet = new SuperchainVotingFacet(portfolioFactory, votingConfig, votingEscrow, voter);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "SuperchainVotingFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = SuperchainVotingFacet.vote.selector;
        selectors[1] = VotingFacet.voteForLaunchpadToken.selector;
        selectors[2] = VotingFacet.setVotingMode.selector;
        selectors[3] = VotingFacet.isManualVoting.selector;
        selectors[4] = VotingFacet.defaultVote.selector;
        selectors[5] = VotingFacet.batchVote.selector;
        selectors[6] = VotingFacet.batchVoteForLaunchpadToken.selector;
        selectors[7] = VotingFacet.isElligibleForManualVoting.selector;
        return selectors;
    }
}

