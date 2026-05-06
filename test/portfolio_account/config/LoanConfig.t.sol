// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * LoanConfig — direct unit tests for the new `ltv` field and accessors.
 *
 * Coverage targets the freshly added surface:
 *   - setLtv(uint256) — onlyOwner; rejects > MAX_FEE_BPS; accepts 0
 *     (0 is the deliberate escape hatch back to the cash-flow branch)
 *   - getLtv() — round-trips the last set value
 *
 * Why these tests matter:
 *   The `ltv` field switches the collateral managers between two completely
 *   different max-loan formulas. A bug in setLtv (accepting > 10000, missing
 *   onlyOwner, mis-storing) silently flips behavior or grants full collateral
 *   as borrow capacity.
 * =========================================================================*/

import {Test} from "forge-std/Test.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {ILoanConfig} from "../../../src/facets/account/config/ILoanConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract LoanConfigTest is Test {
    LoanConfig internal cfg;
    address internal owner = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal stranger = address(0xBEEF);

    uint256 internal constant MAX_BPS = 10_000; // mirrors LoanConfig.MAX_FEE_BPS

    function setUp() public {
        // Atomic init — same shape as DeployPortfolioFactoryConfig.
        LoanConfig impl = new LoanConfig();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(LoanConfig.initialize, (owner, 20_00, 5_00, 1_00))
        );
        cfg = LoanConfig(address(proxy));
    }

    // ---------------- setLtv access control + bounds ----------------

    function test_setLtv_onlyOwner_revertsForStranger() public {
        // OZ Ownable2Step revert encoding: OwnableUnauthorizedAccount(address).
        // We don't pin the exact selector — just verify a non-owner cannot set.
        vm.prank(stranger);
        vm.expectRevert();
        cfg.setLtv(7000);
    }

    /// @notice setLtv(0) is an admin escape hatch — it flips the market back
    ///         to the cash-flow branch. The test pins the spec: 0 is allowed,
    ///         and getLtv reports 0 afterwards.
    function test_setLtv_acceptsZero() public {
        vm.prank(owner);
        cfg.setLtv(0);
        assertEq(cfg.getLtv(), 0);
    }

    function test_setLtv_revertsAboveMaxFeeBps() public {
        vm.prank(owner);
        vm.expectRevert(bytes("LTV cannot exceed max fee"));
        cfg.setLtv(MAX_BPS + 1);
    }

    function test_setLtv_acceptsBoundaryOne() public {
        vm.prank(owner);
        cfg.setLtv(1);
        assertEq(cfg.getLtv(), 1);
    }

    function test_setLtv_acceptsBoundaryMaxBps() public {
        vm.prank(owner);
        cfg.setLtv(MAX_BPS);
        assertEq(cfg.getLtv(), MAX_BPS);
    }

    function test_setLtv_storesLastValueWritten() public {
        vm.startPrank(owner);
        cfg.setLtv(5000);
        assertEq(cfg.getLtv(), 5000);
        cfg.setLtv(8000);
        assertEq(cfg.getLtv(), 8000);
        vm.stopPrank();
    }

    /// @notice Round-trip: an admin can flip into the LTV branch and back to
    ///         cash-flow via setLtv(0). This is by design — losing this lever
    ///         would strand a market in like-to-like mode after a misconfig.
    function test_setLtv_roundTripsBetweenLtvAndCashFlow() public {
        vm.startPrank(owner);
        cfg.setLtv(7000);
        assertEq(cfg.getLtv(), 7000);
        cfg.setLtv(0);
        assertEq(cfg.getLtv(), 0);
        cfg.setLtv(5000);
        assertEq(cfg.getLtv(), 5000);
        vm.stopPrank();
    }

    // ---------------- getLtv default ----------------

    function test_getLtv_defaultsToZeroAfterInitialize() public view {
        // Initialize does not touch ltv. The branching code in the collateral
        // managers leans on this default to pick the cash-flow formula.
        assertEq(cfg.getLtv(), 0);
    }

    // ---------------- ILoanConfig interface conformance ----------------

    function test_ILoanConfig_setLtv_reachableViaInterface() public {
        vm.prank(owner);
        ILoanConfig(address(cfg)).setLtv(4242);
        assertEq(cfg.getLtv(), 4242);
    }
}
