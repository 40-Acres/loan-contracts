// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * LoanConfig — unit tests for the new `treasury` storage field and accessors.
 *
 * Coverage targets the freshly added surface:
 *   - setTreasury(address) — onlyOwner; rejects address(0); emits TreasuryUpdated
 *   - getTreasury() — falls back to owner() when storage is address(0)
 *
 * Why these tests matter:
 *   getTreasury() is read by ClaimingFacet and RewardsProcessingFacet to route
 *   the treasury cut of every harvest and the zero-balance fee. A bug in the
 *   fallback or in the setter silently routes protocol fees to the wrong
 *   address — or, worse, leaks them when storage is uninitialized on a fresh
 *   proxy.
 * =========================================================================*/

import {Test} from "forge-std/Test.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract LoanConfigTreasuryTest is Test {
    LoanConfig internal cfg;
    address internal owner = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal stranger = address(0xBEEF);
    address internal treasuryA = address(0x7EA51);
    address internal treasuryB = address(0x7EA52);

    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    function setUp() public {
        LoanConfig impl = new LoanConfig();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(LoanConfig.initialize, (owner, 20_00, 5_00, 1_00))
        );
        cfg = LoanConfig(address(proxy));
    }

    // ---------------- getTreasury fallback (unset) ----------------

    /// @notice Fresh proxy: storage.treasury == address(0); getter must return owner().
    function test_getTreasury_fallbackToOwner_whenUnset() public view {
        assertEq(cfg.getTreasury(), owner, "unset storage must fall back to owner()");
    }

    // ---------------- setTreasury access control ----------------

    function test_setTreasury_revertsForNonOwner() public {
        // OZ Ownable encodes OwnableUnauthorizedAccount(stranger).
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger)
        );
        cfg.setTreasury(treasuryA);
    }

    function test_setTreasury_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(LoanConfig.InvalidTreasury.selector);
        cfg.setTreasury(address(0));
    }

    // ---------------- setTreasury emits event with exact args ----------------

    /// @notice First-set transition: oldTreasury == address(0), newTreasury == T.
    ///         This pins the audit invariant — the event MUST report the
    ///         pre-storage value (zero), not owner() — because indexers rely on
    ///         the raw transition, not the fallback view.
    function test_setTreasury_emitsTreasuryUpdated_fromZeroOnFirstSet() public {
        vm.expectEmit(true, true, true, true, address(cfg));
        emit TreasuryUpdated(address(0), treasuryA);
        vm.prank(owner);
        cfg.setTreasury(treasuryA);
    }

    /// @notice Second-set: oldTreasury == previous value, newTreasury == new.
    function test_setTreasury_emitsTreasuryUpdated_fromPreviousOnRotation() public {
        vm.prank(owner);
        cfg.setTreasury(treasuryA);

        vm.expectEmit(true, true, true, true, address(cfg));
        emit TreasuryUpdated(treasuryA, treasuryB);
        vm.prank(owner);
        cfg.setTreasury(treasuryB);
    }

    // ---------------- getTreasury after explicit set ----------------

    function test_getTreasury_returnsStoredValue_afterSet() public {
        vm.prank(owner);
        cfg.setTreasury(treasuryA);
        assertEq(cfg.getTreasury(), treasuryA, "explicit set must override owner fallback");
    }

    /// @notice Owner rotation must not retroactively change the configured
    ///         treasury: once set, treasury is decoupled from owner().
    function test_getTreasury_stableAcrossOwnerChange() public {
        vm.prank(owner);
        cfg.setTreasury(treasuryA);

        // Transfer ownership (Ownable2Step => transfer + accept).
        address newOwner = address(0xC0FFEE);
        vm.prank(owner);
        cfg.transferOwnership(newOwner);
        vm.prank(newOwner);
        cfg.acceptOwnership();

        assertEq(cfg.owner(), newOwner, "ownership transferred");
        assertEq(cfg.getTreasury(), treasuryA, "treasury must not follow owner");
    }

    /// @notice Fallback must follow the CURRENT owner when unset — proves the
    ///         getter reads owner() at call time rather than caching at init.
    function test_getTreasury_fallback_followsCurrentOwner() public {
        address newOwner = address(0xC0FFEE);
        vm.prank(owner);
        cfg.transferOwnership(newOwner);
        vm.prank(newOwner);
        cfg.acceptOwnership();

        assertEq(cfg.getTreasury(), newOwner, "fallback tracks current owner()");
    }
}
