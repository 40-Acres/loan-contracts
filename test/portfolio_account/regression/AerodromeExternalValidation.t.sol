// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {BaseForkSetup} from "./BaseForkSetup.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";

/**
 * @title AerodromeExternalValidation
 * @dev Tests that external on-chain addresses are valid contracts and that
 *      the veNFT used in tests exists. Requires Base fork.
 */
contract AerodromeExternalValidation is BaseForkSetup {
    // ─── External addresses are contracts ────────────────────────────

    function testVotingEscrowIsContract() public view {
        assertGt(VOTING_ESCROW.code.length, 0, "VOTING_ESCROW should be a contract");
    }

    function testVoterIsContract() public view {
        assertGt(VOTER.code.length, 0, "VOTER should be a contract");
    }

    function testRewardsDistributorIsContract() public view {
        assertGt(REWARDS_DISTRIBUTOR.code.length, 0, "REWARDS_DISTRIBUTOR should be a contract");
    }

    function testUsdcIsContract() public view {
        assertGt(USDC.code.length, 0, "USDC should be a contract");
    }

    function testAeroIsContract() public view {
        assertGt(AERO.code.length, 0, "AERO should be a contract");
    }

    // ─── veNFT exists ────────────────────────────────────────────────

    function testVeNFTExists() public view {
        address owner = IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId);
        assertTrue(owner != address(0), "veNFT 84297 should exist");
        // After setUp, the veNFT is transferred to the portfolio account
        assertEq(owner, portfolioAccount, "veNFT should be in portfolio account after setUp");
    }
}
