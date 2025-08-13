// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Loan as LoanV2Contract} from "../src/LoanV2.sol";

// Minimal non-UUPS implementation to assert OZ UUPS guard reverts
contract NotUUPS {
    function poke() external {}
}

contract LoanUpgradeFlowTest is Test {
    LoanV2Contract public loan;
    address public proposer = address(0xBEEF);
    address public ownerAddress;

    // Events mirrored from LoanV2 for expectEmit checks
    event ProposerSet(address proposer);
    event UpgradeProposed(address implementation);
    event UpgradeAccepted(address implementation);
    event UpgradeCancelled();


    function setUp() public {
        uint256 fork = vm.createFork("https://mainnet.base.org");
        vm.selectFork(fork);

        // Use live proxy on Base mainnet fork
        loan = LoanV2Contract(address(0x87f18b377e625b62c708D5f6EA96EC193558EFD0));
        ownerAddress = loan.owner();
        // Upgrade live proxy to our new logic and set proposer as owner
        vm.startPrank(ownerAddress);
        LoanV2Contract v2Impl = new LoanV2Contract();
        loan.upgradeToAndCall(address(v2Impl), new bytes(0));
        loan.setProposer(proposer);
        vm.stopPrank();
    }

    function test_success_owner_upgrades_after_proposer_sets() public {
        // New implementation to upgrade to
        LoanV2Contract newImplementation = new LoanV2Contract();

        // Proposer submits proposal
        vm.startPrank(proposer);
        vm.expectEmit(true, true, true, true, address(loan));
        emit UpgradeProposed(address(newImplementation));
        loan.proposeUpgrade(address(newImplementation));
        vm.stopPrank();
        vm.startPrank(ownerAddress);
        vm.expectEmit(true, true, true, true, address(loan));
        emit UpgradeAccepted(address(newImplementation));
        loan.upgradeToAndCall(address(newImplementation), new bytes(0));

        // Proposal is cleared after acceptance
        assertEq(loan.proposedUpgrade(), address(0));
        vm.stopPrank();
    }

    function test_success_cancel_and_enforce_matching_implementation() public {
        // First proposal
        LoanV2Contract proposedImpl = new LoanV2Contract();
        vm.startPrank(proposer);
        loan.proposeUpgrade(address(proposedImpl));
        vm.stopPrank();

        // Owner tries to upgrade to a different implementation -> revert
        LoanV2Contract differentImpl = new LoanV2Contract();
        vm.startPrank(ownerAddress);
        vm.expectRevert();
        loan.upgradeToAndCall(address(differentImpl), new bytes(0));

        // Owner cancels proposal
        loan.cancelProposedUpgrade();
        assertEq(loan.proposedUpgrade(), address(0));

        // Without a proposal, upgrade should revert
        vm.expectRevert();
        loan.upgradeToAndCall(address(proposedImpl), new bytes(0));
        vm.stopPrank();
    }

    function test_revert_setProposer_nonOwner() public {
        vm.expectRevert();
        loan.setProposer(address(0xCAFE));
    }

    function test_success_setProposer_emits_and_sets() public {
        vm.startPrank(ownerAddress);
        vm.expectEmit(true, true, true, true, address(loan));
        emit ProposerSet(address(0x1234));
        loan.setProposer(address(0x1234));
        vm.stopPrank();
        // sanity: proposing now from new proposer should work
        vm.startPrank(address(0x1234));
        LoanV2Contract impl = new LoanV2Contract();
        loan.proposeUpgrade(address(impl));
        vm.stopPrank();
        // reset state for other tests
        vm.startPrank(ownerAddress);
        loan.cancelProposedUpgrade();
        loan.setProposer(proposer);
        vm.stopPrank();
    }

    function test_revert_proposeUpgrade_notProposer() public {
        LoanV2Contract impl = new LoanV2Contract();
        vm.expectRevert();
        loan.proposeUpgrade(address(impl));
    }

    function test_revert_proposeUpgrade_zeroAddress() public {
        vm.startPrank(proposer);
        vm.expectRevert();
        loan.proposeUpgrade(address(0));
        vm.stopPrank();
    }

    function test_success_repropose_overwrites_previous_impl() public {
        vm.startPrank(proposer);
        LoanV2Contract impl1 = new LoanV2Contract();
        loan.proposeUpgrade(address(impl1));
        LoanV2Contract impl2 = new LoanV2Contract();
        loan.proposeUpgrade(address(impl2));
        assertEq(loan.proposedUpgrade(), address(impl2));
        vm.stopPrank();
        // cleanup
        vm.startPrank(ownerAddress);
        loan.cancelProposedUpgrade();
        vm.stopPrank();
    }

    function test_revert_upgrade_without_proposal() public {
        // ensure no pending proposal
        vm.startPrank(ownerAddress);
        if (loan.proposedUpgrade() != address(0)) {
            loan.cancelProposedUpgrade();
        }
        LoanV2Contract impl = new LoanV2Contract();
        vm.expectRevert();
        loan.upgradeToAndCall(address(impl), new bytes(0));
        vm.stopPrank();
    }

    function test_revert_upgrade_by_nonOwner() public {
        LoanV2Contract impl = new LoanV2Contract();
        vm.startPrank(proposer);
        loan.proposeUpgrade(address(impl));
        vm.stopPrank();
        address attacker = address(0xDEAD);
        vm.startPrank(attacker);
        vm.expectRevert();
        loan.upgradeToAndCall(address(impl), new bytes(0));
        vm.stopPrank();
        // cleanup
        vm.startPrank(ownerAddress);
        loan.cancelProposedUpgrade();
        vm.stopPrank();
    }

    function test_revert_upgrade_to_different_impl_than_proposed() public {
        LoanV2Contract proposed = new LoanV2Contract();
        LoanV2Contract different = new LoanV2Contract();
        vm.startPrank(proposer);
        loan.proposeUpgrade(address(proposed));
        vm.stopPrank();
        vm.startPrank(ownerAddress);
        vm.expectRevert();
        loan.upgradeToAndCall(address(different), new bytes(0));
        // cleanup
        loan.cancelProposedUpgrade();
        vm.stopPrank();
    }

    function test_revert_upgrade_to_old_impl_after_reproposal() public {
        // propose impl1 then repropose impl2
        vm.startPrank(proposer);
        LoanV2Contract impl1 = new LoanV2Contract();
        loan.proposeUpgrade(address(impl1));
        LoanV2Contract impl2 = new LoanV2Contract();
        loan.proposeUpgrade(address(impl2));
        vm.stopPrank();
        // only the latest proposal is valid
        vm.startPrank(ownerAddress);
        vm.expectRevert();
        loan.upgradeToAndCall(address(impl1), new bytes(0));
        vm.stopPrank();
    }

    function test_success_upgrade_to_new_impl_after_reproposal() public {
        vm.startPrank(proposer);
        LoanV2Contract impl1 = new LoanV2Contract();
        loan.proposeUpgrade(address(impl1));
        LoanV2Contract impl2 = new LoanV2Contract();
        loan.proposeUpgrade(address(impl2));
        vm.stopPrank();
        vm.startPrank(ownerAddress);
        vm.expectEmit(true, true, true, true, address(loan));
        emit UpgradeAccepted(address(impl2));
        loan.upgradeToAndCall(address(impl2), new bytes(0));
        vm.stopPrank();
    }

    function test_revert_upgrade_to_non_uups_implementation() public {
        // propose a non-UUPS implementation
        NotUUPS bad = new NotUUPS();
        vm.startPrank(proposer);
        loan.proposeUpgrade(address(bad));
        vm.stopPrank();
        // OZ UUPS guard should revert
        vm.startPrank(ownerAddress);
        vm.expectRevert();
        loan.upgradeToAndCall(address(bad), new bytes(0));
        vm.stopPrank();
        // cleanup
        vm.startPrank(ownerAddress);
        loan.cancelProposedUpgrade();
        vm.stopPrank();
    }

    function test_revert_accept_upgrade_requires_new_proposal() public {
        LoanV2Contract impl = new LoanV2Contract();
        vm.startPrank(proposer);
        loan.proposeUpgrade(address(impl));
        vm.stopPrank();
        vm.startPrank(ownerAddress);
        loan.upgradeToAndCall(address(impl), new bytes(0));
        // second upgrade without new proposal should revert
        LoanV2Contract impl2 = new LoanV2Contract();
        vm.expectRevert();
        loan.upgradeToAndCall(address(impl2), new bytes(0));
        vm.stopPrank();
    }

    function test_revert_cancel_by_non_owner() public {
        vm.expectRevert();
        loan.cancelProposedUpgrade();
    }

    function test_success_propose_after_cancel() public {
        // propose then cancel then propose again
        vm.startPrank(proposer);
        LoanV2Contract impl = new LoanV2Contract();
        loan.proposeUpgrade(address(impl));
        vm.stopPrank();
        vm.startPrank(ownerAddress);
        loan.cancelProposedUpgrade();
        vm.stopPrank();
        vm.startPrank(proposer);
        LoanV2Contract impl2 = new LoanV2Contract();
        loan.proposeUpgrade(address(impl2));
        assertEq(loan.proposedUpgrade(), address(impl2));
        vm.stopPrank();
        // cleanup
        vm.startPrank(ownerAddress);
        loan.cancelProposedUpgrade();
        vm.stopPrank();
    }

    function test_success_owner_can_cancel_proposed_upgrade() public {
        // proposer submits
        vm.startPrank(proposer);
        LoanV2Contract impl = new LoanV2Contract();
        loan.proposeUpgrade(address(impl));
        vm.stopPrank();

        // owner cancels
        vm.startPrank(ownerAddress);
        vm.expectEmit(true, true, true, true, address(loan));
        emit UpgradeCancelled();
        loan.cancelProposedUpgrade();
        vm.stopPrank();

        // ensure cleared
        assertEq(loan.proposedUpgrade(), address(0));
    }

    function test_success_proposer_can_cancel() public {
        // proposer submits
        vm.startPrank(proposer);
        LoanV2Contract impl = new LoanV2Contract();
        loan.proposeUpgrade(address(impl));
        // proposer cancels
        vm.expectEmit(true, true, true, true, address(loan));
        emit UpgradeCancelled();
        loan.cancelProposedUpgrade();
        vm.stopPrank();
        // ensure cleared
        assertEq(loan.proposedUpgrade(), address(0));
    }
}


