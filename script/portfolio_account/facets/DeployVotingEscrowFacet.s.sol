// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {VotingEscrowFacet} from "../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";

contract DeployVotingEscrowFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");
        address VOTER = vm.envAddress("VOTER");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        VotingEscrowFacet facet = new VotingEscrowFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, VOTING_ESCROW, VOTER);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "VotingEscrowFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig, address votingEscrow, address voter) external {
        VotingEscrowFacet newFacet = new VotingEscrowFacet(portfolioFactory, portfolioAccountConfig, votingEscrow, voter);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "VotingEscrowFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = VotingEscrowFacet.createLock.selector;
        selectors[1] = VotingEscrowFacet.increaseLock.selector;
        return selectors;
    }
}

