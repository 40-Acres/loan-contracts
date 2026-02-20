// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {BaseDeploymentSetup} from "../../../../test/portfolio_account/regression/BaseDeploymentSetup.sol";
import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";

/**
 * @title BaseForkSetup
 * @dev Extends BaseDeploymentSetup with a Base chain fork at block 38869188.
 *      Tests that interact with real on-chain contracts (veNFT, Voter,
 *      RewardsDistributor, USDC transfers) should extend this.
 */
abstract contract BaseForkSetup is BaseDeploymentSetup {
    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 38869188);
        super.setUp();
    }

    /// @dev Fork provides real contracts, no mocks needed
    function _setupExternalMocks() internal override {}

    /// @dev Override to transfer veNFT to portfolio account after creation
    function _createUserPortfolio() internal override {
        portfolioAccount = portfolioFactory.createAccount(user);

        // Transfer veNFT tokenId 84297 to portfolio account
        address tokenOwner = IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId);
        vm.startPrank(tokenOwner);
        IVotingEscrow(VOTING_ESCROW).transferFrom(tokenOwner, portfolioAccount, tokenId);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }
}
