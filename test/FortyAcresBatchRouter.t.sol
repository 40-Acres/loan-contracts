// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {FortyAcresBatchRouter} from "../src/swap/FortyAcresBatchRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * FortyAcresBatchRouter unit tests.
 *
 * Threat model context: the legacy consumers (BlackholeLoanV2._processRewards and
 * XPharaohFacet.xPharProcessRewards) grant this router an INFINITE allowance on every
 * reward token before forwarding an opaque blob, and only revoke it after the call
 * returns. During that window the router is a confused deputy for anything that can
 * reach it. Two independent gates stand between an arbitrary actor and those
 * allowances: the caller gate and the swapTarget allowlist. testAttack_* below pins
 * both, and the negative control proves the allowlist is load-bearing on its own.
 *
 * Observations recorded during this run (NOT fixed here, see final report):
 *  - `swap.swapTarget == address(this)` in _executeSwap is unreachable: _setApprovedTarget
 *    refuses to allowlist the router itself, and the allowlist check runs first. Such a
 *    batch reverts TargetNotApproved, never InvalidTarget.
 *  - `initialize` cannot be called with initialTarget == address(0); the router can never
 *    exist with an empty target allowlist.
 *  - A factory whose `isPortfolio` reverts or is missing bricks every non-static caller.
 */
contract FortyAcresBatchRouterTest is Test {
    // Hardcoded absolutes. via-ir caches block.timestamp across warps, so never re-read it.
    uint256 internal constant NOW = 1_700_000_000;
    uint256 internal constant DEADLINE = 1_700_003_600;

    bytes32 internal constant ROUTER_SLOT = keccak256("storage.FortyAcresBatchRouter");

    FortyAcresBatchRouter internal impl;
    FortyAcresBatchRouter internal router;
    MockSwapTarget internal target;
    MockPortfolioFactory internal factory;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;
    MockERC20 internal usdc;
    MockERC20 internal weth;

    address internal owner = address(uint160(uint256(keccak256("owner"))));
    address internal alice = address(uint160(uint256(keccak256("alice"))));
    address internal attacker = address(uint160(uint256(keccak256("attacker"))));
    address internal portfolio = address(uint160(uint256(keccak256("portfolio"))));
    address internal eoa = address(uint160(uint256(keccak256("eoa"))));

    event TargetApprovalSet(address indexed target, bool approved);
    event CallerApprovalSet(address indexed caller, bool approved);
    event FactoryApprovalSet(address indexed factory, bool approved);
    event BatchSwap(address indexed caller, uint256 swaps, uint256 outputs);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    function setUp() public {
        vm.warp(NOW);

        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        tokenC = new MockERC20("C", "C", 6);
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);

        target = new MockSwapTarget();
        factory = new MockPortfolioFactory();
        factory.setPortfolio(portfolio, true);

        impl = new FortyAcresBatchRouter();
        router = FortyAcresBatchRouter(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(FortyAcresBatchRouter.initialize, (owner, address(target), alice, address(0)))
                )
            )
        );

        vm.label(address(router), "BatchRouter");
        vm.label(address(target), "MockSwapTarget");
        vm.label(alice, "alice");
        vm.label(attacker, "attacker");

        tokenA.mint(alice, 1_000e18);
        tokenB.mint(alice, 1_000e18);
        tokenC.mint(alice, 1_000e6);

        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- helpers

    function _swap(address inputToken, uint256 inputAmount, address outputToken, uint256 outputAmount)
        internal
        view
        returns (FortyAcresBatchRouter.Swap memory s)
    {
        s = FortyAcresBatchRouter.Swap({
            inputToken: inputToken,
            inputAmount: inputAmount,
            swapTarget: address(target),
            swapData: abi.encodeCall(MockSwapTarget.swap, (inputToken, inputAmount, outputToken, outputAmount))
        });
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _one(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    /// F-1 makes setApprovedTarget reject ERC20-shaped targets, so a token can no longer
    /// be allowlisted through the setter. To still exercise the swapMulti-time guards that
    /// fire when a target coincides with an input/output token, force the allowlist entry
    /// directly. approvedTargets mapping lives at slot P+0.
    function _forceApproveTarget(address t) internal {
        uint256 base = uint256(ROUTER_SLOT);
        vm.store(address(router), keccak256(abi.encode(t, base)), bytes32(uint256(1)));
        assertTrue(router.isApprovedTarget(t), "force-approve failed");
    }

    // ------------------------------------------------------------- happy path

    /// 3 inputs collapsing to a single output token, exact accounting on every leg.
    function test_swapMulti_threeInputsOneOutput() public {
        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](3);
        swaps[0] = _swap(address(tokenA), 100e18, address(usdc), 40e6);
        swaps[1] = _swap(address(tokenB), 200e18, address(usdc), 60e6);
        swaps[2] = _swap(address(tokenC), 300e6, address(usdc), 25e6);

        vm.expectEmit(true, false, false, true, address(router));
        emit BatchSwap(alice, 3, 1);

        vm.prank(alice);
        uint256[] memory outs = router.swapMulti(swaps, _one(address(usdc)), _one(uint256(125e6)), DEADLINE);

        assertEq(outs.length, 1, "one output");
        assertEq(outs[0], 125e6, "delta equals sum of legs");
        assertEq(usdc.balanceOf(alice), 125e6, "proceeds land on caller");

        // Router must never retain anything.
        assertEq(usdc.balanceOf(address(router)), 0, "router usdc dust");
        assertEq(tokenA.balanceOf(address(router)), 0, "router A dust");
        assertEq(tokenB.balanceOf(address(router)), 0, "router B dust");
        assertEq(tokenC.balanceOf(address(router)), 0, "router C dust");

        // Inputs were actually consumed by the target, not just shuffled.
        assertEq(tokenA.balanceOf(address(target)), 100e18, "target holds A");
        assertEq(tokenB.balanceOf(address(target)), 200e18, "target holds B");
        assertEq(tokenC.balanceOf(address(target)), 300e6, "target holds C");
        assertEq(tokenA.balanceOf(alice), 900e18, "alice A debited");

        // Approvals fully unwound.
        assertEq(tokenA.allowance(address(router), address(target)), 0, "A approval revoked");
        assertEq(tokenB.allowance(address(router), address(target)), 0, "B approval revoked");
        assertEq(tokenC.allowance(address(router), address(target)), 0, "C approval revoked");
    }

    /// 2 inputs fanning out to 2 distinct outputs, each with its own minOut.
    function test_swapMulti_multiOutput() public {
        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](2);
        swaps[0] = _swap(address(tokenA), 100e18, address(usdc), 50e6);
        swaps[1] = _swap(address(tokenB), 200e18, address(weth), 3e18);

        address[] memory outputs = new address[](2);
        outputs[0] = address(usdc);
        outputs[1] = address(weth);
        uint256[] memory minOuts = new uint256[](2);
        minOuts[0] = 50e6;
        minOuts[1] = 3e18;

        vm.prank(alice);
        uint256[] memory outs = router.swapMulti(swaps, outputs, minOuts, DEADLINE);

        assertEq(outs[0], 50e6, "usdc out");
        assertEq(outs[1], 3e18, "weth out");
        assertEq(usdc.balanceOf(alice), 50e6, "alice usdc");
        assertEq(weth.balanceOf(alice), 3e18, "alice weth");
        assertEq(usdc.balanceOf(address(router)), 0, "no usdc left");
        assertEq(weth.balanceOf(address(router)), 0, "no weth left");
    }

    /// One leg short of its own minOut still reverts even if the other output is fine.
    function testRevert_multiOutput_secondMinOutMissed() public {
        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](2);
        swaps[0] = _swap(address(tokenA), 100e18, address(usdc), 50e6);
        swaps[1] = _swap(address(tokenB), 200e18, address(weth), 1e18);

        address[] memory outputs = new address[](2);
        outputs[0] = address(usdc);
        outputs[1] = address(weth);
        uint256[] memory minOuts = new uint256[](2);
        minOuts[0] = 50e6;
        minOuts[1] = 3e18;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(FortyAcresBatchRouter.InsufficientOutput.selector, address(weth), 1e18, 3e18)
        );
        router.swapMulti(swaps, outputs, minOuts, DEADLINE);
    }

    /// F-2: minOut==0 is now rejected, so the former empty-swaps no-op reverts. A truly
    /// empty batch (outputTokens.length==0) already reverts LengthMismatch, so no
    /// legitimate no-op path remains.
    function testRevert_emptySwaps_zeroMinOutReverts() public {
        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.ZeroMinOut.selector, uint256(0)));
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(0)), DEADLINE);
    }

    // ------------------------------------------------------------ caller gate

    function testRevert_swapMulti_callerNotApproved() public {
        tokenA.mint(attacker, 100e18);
        vm.prank(attacker);
        tokenA.approve(address(router), type(uint256).max);

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = _swap(address(tokenA), 100e18, address(usdc), 10e6);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.CallerNotApproved.selector, attacker));
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(0)), DEADLINE);
    }

    /// The gate runs before every other validation, so a bad batch from a bad caller
    /// still reports the caller problem.
    function test_callerGate_precedesDeadlineAndLengthChecks() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.CallerNotApproved.selector, attacker));
        router.swapMulti(new FortyAcresBatchRouter.Swap[](0), new address[](0), new uint256[](0), NOW - 1);
    }

    function test_callerGate_staticCallerRevocable() public {
        assertTrue(router.isApprovedCaller(alice), "seeded caller");

        vm.expectEmit(true, false, false, true, address(router));
        emit CallerApprovalSet(alice, false);
        vm.prank(owner);
        router.setApprovedCaller(alice, false);

        assertFalse(router.isApprovedCaller(alice), "revoked");

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = _swap(address(tokenA), 100e18, address(usdc), 10e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.CallerNotApproved.selector, alice));
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(0)), DEADLINE);
    }

    /// Any live account of the approved factory is a caller without a per-account tx.
    function test_callerGate_factoryPortfolioAllowed() public {
        vm.expectEmit(true, false, false, true, address(router));
        emit FactoryApprovalSet(address(factory), true);
        vm.prank(owner);
        router.setApprovedFactory(address(factory));

        assertEq(router.getApprovedFactory(), address(factory), "factory recorded");
        assertTrue(router.isApprovedCaller(portfolio), "portfolio allowed");
        assertFalse(router.isApprovedCaller(attacker), "non-portfolio rejected");

        tokenA.mint(portfolio, 100e18);
        vm.prank(portfolio);
        tokenA.approve(address(router), type(uint256).max);

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = _swap(address(tokenA), 100e18, address(usdc), 10e6);

        vm.prank(portfolio);
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(10e6)), DEADLINE);
        assertEq(usdc.balanceOf(portfolio), 10e6, "portfolio swapped");
    }

    function testRevert_callerGate_factoryNonPortfolio() public {
        vm.prank(owner);
        router.setApprovedFactory(address(factory));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.CallerNotApproved.selector, attacker));
        router.swapMulti(new FortyAcresBatchRouter.Swap[](0), _one(address(usdc)), _one(uint256(0)), DEADLINE);
    }

    /// Replacing the factory immediately invalidates the previous factory's accounts.
    function test_callerGate_replacingFactoryRevokesOldAccounts() public {
        vm.prank(owner);
        router.setApprovedFactory(address(factory));
        assertTrue(router.isApprovedCaller(portfolio), "allowed under factory A");

        MockPortfolioFactory factoryB = new MockPortfolioFactory();
        vm.prank(owner);
        router.setApprovedFactory(address(factoryB));

        assertEq(router.getApprovedFactory(), address(factoryB), "factory replaced");
        assertFalse(router.isApprovedCaller(portfolio), "factory A account revoked");
    }

    function test_callerGate_zeroFactoryDisablesFactoryPath() public {
        vm.prank(owner);
        router.setApprovedFactory(address(factory));
        assertTrue(router.isApprovedCaller(portfolio), "allowed");

        vm.expectEmit(true, false, false, true, address(router));
        emit FactoryApprovalSet(address(0), false);
        vm.prank(owner);
        router.setApprovedFactory(address(0));

        assertEq(router.getApprovedFactory(), address(0), "cleared");
        assertFalse(router.isApprovedCaller(portfolio), "factory path off");
        // Static callers are unaffected by clearing the factory.
        assertTrue(router.isApprovedCaller(alice), "static caller survives");
    }

    /// A static approval outranks the factory, so it works with no factory configured.
    function test_callerGate_staticCallerNeedsNoFactory() public view {
        assertEq(router.getApprovedFactory(), address(0), "no factory");
        assertTrue(router.isApprovedCaller(alice), "static approval suffices");
    }

    /// Documents a live-config risk: a factory that cannot answer isPortfolio bricks
    /// every caller that is not statically approved.
    function test_callerGate_brokenFactoryBricksNonStaticCallers() public {
        BrokenFactory broken = new BrokenFactory();
        vm.prank(owner);
        router.setApprovedFactory(address(broken));

        vm.expectRevert();
        router.isApprovedCaller(attacker);

        // Statically approved callers still short-circuit before the staticcall.
        assertTrue(router.isApprovedCaller(alice), "static caller unaffected");
    }

    // --------------------------------------------------- confused deputy tests

    /**
     * Layer 1: the caller gate.
     *
     * A legacy loan sits with an infinite approval to the router. An unrelated EOA
     * points swapTarget at the reward token and hands it a transferFrom that spends
     * the victim's allowance. The caller gate rejects it outright.
     */
    function testAttack_ConfusedDeputyBlockedByCallerGate() public {
        VictimLoan victim = new VictimLoan();
        tokenA.mint(address(victim), 500e18);
        victim.approveAll(address(tokenA), address(router));
        assertEq(tokenA.allowance(address(victim), address(router)), type(uint256).max, "victim exposed");

        tokenB.mint(attacker, 1e18);
        vm.prank(attacker);
        tokenB.approve(address(router), type(uint256).max);

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = FortyAcresBatchRouter.Swap({
            inputToken: address(tokenB),
            inputAmount: 1e18,
            swapTarget: address(tokenA),
            swapData: abi.encodeCall(IERC20.transferFrom, (address(victim), attacker, 500e18))
        });

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.CallerNotApproved.selector, attacker));
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(0)), DEADLINE);

        assertEq(tokenA.balanceOf(address(victim)), 500e18, "victim untouched");
    }

    /**
     * Layer 2: the target allowlist holds even for an APPROVED caller.
     *
     * Approved callers are loan proxies and portfolio accounts, which are themselves
     * upgradeable/extensible. If one is ever compromised or induced to forward
     * attacker-chosen tradeData, the allowlist is the last line of defense.
     */
    function testAttack_ConfusedDeputyBlockedByAllowlist() public {
        VictimLoan victim = new VictimLoan();
        tokenA.mint(address(victim), 500e18);
        victim.approveAll(address(tokenA), address(router));

        // Attacker is a legitimate caller now; only the allowlist can stop them.
        vm.prank(owner);
        router.setApprovedCaller(attacker, true);

        tokenB.mint(attacker, 1e18);
        vm.prank(attacker);
        tokenB.approve(address(router), type(uint256).max);

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = FortyAcresBatchRouter.Swap({
            inputToken: address(tokenB),
            inputAmount: 1e18,
            swapTarget: address(tokenA), // the victim's reward token, never allowlisted
            swapData: abi.encodeCall(IERC20.transferFrom, (address(victim), attacker, 500e18))
        });

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.TargetNotApproved.selector, address(tokenA)));
        // minOut is a nonzero placeholder: F-2 rejects 0 before the allowlist check.
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(1)), DEADLINE);

        assertEq(tokenA.balanceOf(address(victim)), 500e18, "victim untouched");
        assertEq(tokenA.balanceOf(attacker), 0, "attacker gained nothing");
    }

    /**
     * Depth check on the token-as-target misconfiguration. Two independent guards must
     * both be defeated for a drain, and F-2 closes the second one.
     *
     * Even with the token force-allowlisted (F-1 bypassed) AND the attacker an approved
     * caller, the exfiltrated tokens go straight to the attacker via swapData, so they
     * never become a positive router balance delta. F-2 requires every minOut > 0, which
     * a zero-delta output can never satisfy, so swapMulti reverts InsufficientOutput and
     * the all-or-nothing rollback restores the victim.
     *
     * Operational consequence stands: NEVER allowlist a token contract. This test proves
     * F-2 is a genuine second line, not that the allowlist may be relaxed.
     *
     * NOTE: converted from the prior testAttack_ConfusedDeputySucceedsIfTokenIsApproved,
     * whose "drain succeeds" outcome relied on minOut==0 and is no longer reachable.
     */
    function testAttack_ConfusedDeputyDrainRevertsUnderMinOut() public {
        VictimLoan victim = new VictimLoan();
        tokenA.mint(address(victim), 500e18);
        victim.approveAll(address(tokenA), address(router));

        // Bypass F-1 by writing the allowlist entry directly, and make the attacker a
        // legitimate caller -- the strongest position an attacker can reach.
        _forceApproveTarget(address(tokenA));
        vm.prank(owner);
        router.setApprovedCaller(attacker, true);

        tokenB.mint(attacker, 1e18);
        vm.prank(attacker);
        tokenB.approve(address(router), type(uint256).max);

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = FortyAcresBatchRouter.Swap({
            inputToken: address(tokenB), // != swapTarget
            inputAmount: 1e18,
            swapTarget: address(tokenA),
            swapData: abi.encodeCall(IERC20.transferFrom, (address(victim), attacker, 500e18))
        });

        // Output is usdc, which no leg produces, so the delta is 0 < minOut.
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(FortyAcresBatchRouter.InsufficientOutput.selector, address(usdc), 0, uint256(1))
        );
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(1)), DEADLINE);

        // All-or-nothing rollback restored the victim; the attacker took nothing.
        assertEq(tokenA.balanceOf(address(victim)), 500e18, "victim retained after rollback");
        assertEq(tokenA.balanceOf(attacker), 0, "attacker gained nothing");
    }

    // ------------------------------------------------------ stranded balances

    /// A donation sitting on the router must never be paid out to an unrelated caller.
    function test_strandedBalanceIsNotPaidOut() public {
        usdc.mint(address(router), 500e6); // stranded from an earlier mis-specified batch

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = _swap(address(tokenA), 100e18, address(usdc), 1_000e6);

        vm.prank(alice);
        uint256[] memory outs = router.swapMulti(swaps, _one(address(usdc)), _one(uint256(1_000e6)), DEADLINE);

        assertEq(outs[0], 1_000e6, "delta only");
        assertEq(usdc.balanceOf(alice), 1_000e6, "caller gets delta only");
        assertEq(usdc.balanceOf(address(router)), 500e6, "stranded balance stays put");
    }

    /// A repeated output would double-count one delta and pay the copy out of stranded funds.
    function testRevert_duplicateOutputToken() public {
        usdc.mint(address(router), 500e6);

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = _swap(address(tokenA), 100e18, address(usdc), 100e6);

        address[] memory outputs = new address[](2);
        outputs[0] = address(usdc);
        outputs[1] = address(usdc);
        // Nonzero minOuts so the duplicate check is reached; F-2 checks minOut first.
        uint256[] memory minOuts = new uint256[](2);
        minOuts[0] = 1;
        minOuts[1] = 1;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.DuplicateOutput.selector, address(usdc)));
        router.swapMulti(swaps, outputs, minOuts, DEADLINE);
    }

    /// F-2: a zero minOut is rejected before the balance snapshot, index reported.
    function testRevert_swapMulti_zeroMinOut() public {
        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = _swap(address(tokenA), 100e18, address(usdc), 10e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.ZeroMinOut.selector, uint256(0)));
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(0)), DEADLINE);
    }

    /// The reported index points at the offending output, not just index 0.
    function testRevert_swapMulti_zeroMinOut_reportsIndex() public {
        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](2);
        swaps[0] = _swap(address(tokenA), 100e18, address(usdc), 50e6);
        swaps[1] = _swap(address(tokenB), 200e18, address(weth), 3e18);

        address[] memory outputs = new address[](2);
        outputs[0] = address(usdc);
        outputs[1] = address(weth);
        uint256[] memory minOuts = new uint256[](2);
        minOuts[0] = 50e6;
        minOuts[1] = 0;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.ZeroMinOut.selector, uint256(1)));
        router.swapMulti(swaps, outputs, minOuts, DEADLINE);
    }

    /// minOut is measured on the delta, so a front-run donation cannot satisfy it.
    function test_donationCannotSatisfyMinOut() public {
        // Attacker donates far more than minOut immediately before the batch.
        usdc.mint(address(router), 10_000e6);

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = _swap(address(tokenA), 100e18, address(usdc), 10e6); // real fill is short

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(FortyAcresBatchRouter.InsufficientOutput.selector, address(usdc), 10e6, 100e6)
        );
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(100e6)), DEADLINE);
    }

    // -------------------------------------------------------- input handling

    /// A target that spends only part of the approved input returns the rest to the caller.
    function test_unspentInputRefundedToCaller() public {
        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = FortyAcresBatchRouter.Swap({
            inputToken: address(tokenA),
            inputAmount: 100e18,
            swapTarget: address(target),
            // Target pulls only half of what the router approved.
            swapData: abi.encodeCall(MockSwapTarget.swap, (address(tokenA), 50e18, address(usdc), 40e6))
        });

        vm.prank(alice);
        uint256[] memory outs = router.swapMulti(swaps, _one(address(usdc)), _one(uint256(40e6)), DEADLINE);

        assertEq(outs[0], 40e6, "output delta");
        assertEq(tokenA.balanceOf(alice), 950e18, "half the input returned");
        assertEq(tokenA.balanceOf(address(router)), 0, "no input stranded");
        assertEq(tokenA.balanceOf(address(target)), 50e18, "target kept what it pulled");
        assertEq(tokenA.allowance(address(router), address(target)), 0, "residual approval revoked");
    }

    /// Fee-on-transfer and rebasing inputs are rejected up front, not inside the aggregator.
    function testRevert_inputAmountMismatch_feeOnTransfer() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(alice, 1_000e18);
        vm.prank(alice);
        fot.approve(address(router), type(uint256).max);

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = _swap(address(fot), 1_000e18, address(usdc), 10e6);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(FortyAcresBatchRouter.InputAmountMismatch.selector, address(fot), 1_000e18, 990e18)
        );
        // minOut nonzero placeholder: F-2 rejects 0 before the input pull.
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(1)), DEADLINE);
    }

    // -------------------------------------------------------- validation gate

    function testRevert_expiredDeadline() public {
        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = _swap(address(tokenA), 100e18, address(usdc), 10e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.Expired.selector, NOW - 1));
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(0)), NOW - 1);
    }

    function test_deadlineExactlyNowIsAccepted() public {
        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = _swap(address(tokenA), 100e18, address(usdc), 10e6);

        vm.prank(alice);
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(10e6)), NOW);
        assertEq(usdc.balanceOf(alice), 10e6, "boundary deadline honored");
    }

    function testRevert_lengthMismatch_minOutsShorter() public {
        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](0);
        address[] memory outputs = new address[](2);
        outputs[0] = address(usdc);
        outputs[1] = address(weth);

        vm.prank(alice);
        vm.expectRevert(FortyAcresBatchRouter.LengthMismatch.selector);
        router.swapMulti(swaps, outputs, _one(uint256(0)), DEADLINE);
    }

    function testRevert_lengthMismatch_emptyOutputs() public {
        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = _swap(address(tokenA), 100e18, address(usdc), 10e6);

        vm.prank(alice);
        vm.expectRevert(FortyAcresBatchRouter.LengthMismatch.selector);
        router.swapMulti(swaps, new address[](0), new uint256[](0), DEADLINE);
    }

    /// ZeroAmount carries the offending index, not just the fact of a zero.
    function testRevert_zeroAmountReportsIndex() public {
        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](2);
        swaps[0] = _swap(address(tokenA), 100e18, address(usdc), 10e6);
        swaps[1] = _swap(address(tokenB), 0, address(usdc), 10e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.ZeroAmount.selector, uint256(1)));
        // minOut nonzero placeholder: F-2 rejects 0 before the swap loop's ZeroAmount check.
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(1)), DEADLINE);
    }

    function testRevert_inputIsOutput() public {
        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = _swap(address(tokenA), 100e18, address(usdc), 10e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.InputIsOutput.selector, address(tokenA)));
        // minOut nonzero placeholder: F-2 rejects 0 before the InputIsOutput check.
        router.swapMulti(swaps, _one(address(tokenA)), _one(uint256(1)), DEADLINE);
    }

    function testRevert_targetNotApproved() public {
        MockSwapTarget rogue = new MockSwapTarget();

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = FortyAcresBatchRouter.Swap({
            inputToken: address(tokenA),
            inputAmount: 100e18,
            swapTarget: address(rogue),
            swapData: abi.encodeCall(MockSwapTarget.swap, (address(tokenA), 100e18, address(usdc), 10e6))
        });

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.TargetNotApproved.selector, address(rogue)));
        // minOut nonzero placeholder: F-2 rejects 0 before the allowlist check.
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(1)), DEADLINE);
    }

    function testRevert_invalidTarget_targetEqualsInputToken() public {
        // F-1 blocks approving a token via the setter, so seed the entry directly to reach
        // the swapMulti-time swapTarget==inputToken guard.
        _forceApproveTarget(address(tokenA));

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = FortyAcresBatchRouter.Swap({
            inputToken: address(tokenA),
            inputAmount: 100e18,
            swapTarget: address(tokenA),
            swapData: ""
        });

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.InvalidTarget.selector, address(tokenA)));
        // minOut nonzero placeholder: F-2 rejects 0 before the InvalidTarget check.
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(1)), DEADLINE);
    }

    function testRevert_invalidTarget_targetEqualsOutputToken() public {
        // F-1 blocks approving a token via the setter, so seed the entry directly to reach
        // the swapMulti-time swapTarget==outputToken guard.
        _forceApproveTarget(address(usdc));

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = FortyAcresBatchRouter.Swap({
            inputToken: address(tokenA),
            inputAmount: 100e18,
            swapTarget: address(usdc),
            swapData: ""
        });

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.InvalidTarget.selector, address(usdc)));
        // minOut nonzero placeholder: F-2 rejects 0 before the InvalidTarget check.
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(1)), DEADLINE);
    }

    /// The router can never allowlist itself, so a self-target trips the allowlist first.
    function testRevert_selfTargetRejected() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.InvalidTarget.selector, address(router)));
        router.setApprovedTarget(address(router), true);

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = FortyAcresBatchRouter.Swap({
            inputToken: address(tokenA),
            inputAmount: 100e18,
            swapTarget: address(router),
            swapData: ""
        });

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.TargetNotApproved.selector, address(router)));
        // minOut nonzero placeholder: F-2 rejects 0 before the allowlist check.
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(1)), DEADLINE);
    }

    // ------------------------------------------------------------ bubbling up

    /// Inner revert data must survive so the keeper can diagnose a failed leg.
    function test_innerRevertDataBubbles() public {
        RevertingTarget rogue = new RevertingTarget();
        vm.prank(owner);
        router.setApprovedTarget(address(rogue), true);

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = FortyAcresBatchRouter.Swap({
            inputToken: address(tokenA),
            inputAmount: 100e18,
            swapTarget: address(rogue),
            swapData: abi.encodeCall(RevertingTarget.boom, (42))
        });

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RevertingTarget.TargetBoom.selector, uint256(42)));
        // minOut nonzero placeholder: F-2 rejects 0 before the leg executes.
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(1)), DEADLINE);
    }

    /// A single failing leg reverts the whole batch; earlier legs are not kept.
    function test_allOrNothing_firstLegRolledBack() public {
        RevertingTarget rogue = new RevertingTarget();
        vm.prank(owner);
        router.setApprovedTarget(address(rogue), true);

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](2);
        swaps[0] = _swap(address(tokenA), 100e18, address(usdc), 50e6);
        swaps[1] = FortyAcresBatchRouter.Swap({
            inputToken: address(tokenB),
            inputAmount: 100e18,
            swapTarget: address(rogue),
            swapData: abi.encodeCall(RevertingTarget.boom, (7))
        });

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RevertingTarget.TargetBoom.selector, uint256(7)));
        // minOut nonzero placeholder: F-2 rejects 0 before any leg executes.
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(1)), DEADLINE);

        assertEq(tokenA.balanceOf(alice), 1_000e18, "leg 0 rolled back");
        assertEq(usdc.balanceOf(alice), 0, "no partial proceeds");
    }

    // ------------------------------------------------------------ reentrancy

    function test_reentrancyBlocked() public {
        ReentrantTarget rogue = new ReentrantTarget(address(router), address(usdc), DEADLINE);
        vm.startPrank(owner);
        router.setApprovedTarget(address(rogue), true);
        // Approve the rogue as a caller so the ONLY thing that can stop it is the guard.
        router.setApprovedCaller(address(rogue), true);
        vm.stopPrank();

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = FortyAcresBatchRouter.Swap({
            inputToken: address(tokenA),
            inputAmount: 100e18,
            swapTarget: address(rogue),
            swapData: abi.encodeCall(ReentrantTarget.reenter, ())
        });

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        // minOut nonzero placeholder so the outer batch reaches the reentering leg.
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(1)), DEADLINE);
    }

    // ----------------------------------------------------------------- admin

    function test_initialize_seedsAllowlistOwnerAndCaller() public view {
        assertEq(router.owner(), owner, "owner seeded");
        assertTrue(router.isApprovedTarget(address(target)), "initial target seeded");
        assertTrue(router.isApprovedCaller(alice), "initial caller seeded");
        assertEq(router.getApprovedFactory(), address(0), "zero factory skipped");

        address[] memory list = router.getApprovedTargetsList();
        assertEq(list.length, 1, "one target");
        assertEq(list[0], address(target), "listed");
    }

    function test_initialize_seedsFactoryWhenProvided() public {
        FortyAcresBatchRouter freshImpl = new FortyAcresBatchRouter();
        FortyAcresBatchRouter fresh = FortyAcresBatchRouter(
            address(
                new ERC1967Proxy(
                    address(freshImpl),
                    abi.encodeCall(
                        FortyAcresBatchRouter.initialize, (owner, address(target), address(0), address(factory))
                    )
                )
            )
        );

        assertEq(fresh.getApprovedFactory(), address(factory), "factory seeded");
        assertTrue(fresh.isApprovedCaller(portfolio), "portfolio allowed at genesis");
        assertFalse(fresh.isApprovedCaller(alice), "zero initialCaller skipped");
    }

    function testRevert_initialize_cannotBeCalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        router.initialize(attacker, address(target), attacker, address(0));
    }

    function testRevert_initialize_implementationIsDisabled() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(attacker, address(target), attacker, address(0));
    }

    function testRevert_initialize_zeroInitialTarget() public {
        FortyAcresBatchRouter freshImpl = new FortyAcresBatchRouter();
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.InvalidTarget.selector, address(0)));
        new ERC1967Proxy(
            address(freshImpl),
            abi.encodeCall(FortyAcresBatchRouter.initialize, (owner, address(0), alice, address(0)))
        );
    }

    function testRevert_setApprovedTarget_onlyOwner() public {
        MockSwapTarget other = new MockSwapTarget();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        router.setApprovedTarget(address(other), true);
    }

    function testRevert_setApprovedCaller_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        router.setApprovedCaller(attacker, true);
    }

    function testRevert_setApprovedFactory_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        router.setApprovedFactory(address(factory));
    }

    function testRevert_setApprovedFactory_codelessAddress() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.InvalidTarget.selector, eoa));
        router.setApprovedFactory(eoa);
    }

    function testRevert_setApprovedTarget_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.InvalidTarget.selector, address(0)));
        router.setApprovedTarget(address(0), true);
    }

    function testRevert_setApprovedTarget_codelessEoa() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.InvalidTarget.selector, eoa));
        router.setApprovedTarget(eoa, true);
    }

    /// F-1: an ERC20-shaped target (answers balanceOf) cannot be allowlisted. This is the
    /// front-line block on the token-as-target confused-deputy misconfiguration.
    function testRevert_setApprovedTarget_erc20ShapedTarget() public {
        MockERC20 tokenTarget = new MockERC20("Token", "TKN", 18);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.InvalidTarget.selector, address(tokenTarget)));
        router.setApprovedTarget(address(tokenTarget), true);
    }

    /// F-1 positive control: a target that reverts on balanceOf (like the real 0x
    /// AllowanceHolder and KyberSwap executors) is still approvable.
    function test_setApprovedTarget_allowsNonTokenTarget() public {
        RevertingBalanceOfTarget aggregator = new RevertingBalanceOfTarget();
        vm.expectEmit(true, false, false, true, address(router));
        emit TargetApprovalSet(address(aggregator), true);
        vm.prank(owner);
        router.setApprovedTarget(address(aggregator), true);

        assertTrue(router.isApprovedTarget(address(aggregator)), "aggregator approved");
    }

    /// Revoking is the production kill switch; it must take effect immediately.
    function test_setApprovedTarget_revokeIsKillSwitch() public {
        vm.expectEmit(true, false, false, true, address(router));
        emit TargetApprovalSet(address(target), false);
        vm.prank(owner);
        router.setApprovedTarget(address(target), false);

        assertFalse(router.isApprovedTarget(address(target)), "revoked");
        assertEq(router.getApprovedTargetsList().length, 0, "removed from list");

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = _swap(address(tokenA), 100e18, address(usdc), 10e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.TargetNotApproved.selector, address(target)));
        // minOut nonzero placeholder: F-2 rejects 0 before the allowlist check.
        router.swapMulti(swaps, _one(address(usdc)), _one(uint256(1)), DEADLINE);
    }

    /// Revoking an address that was never approved is allowed and stays a no-op.
    function test_setApprovedTarget_revokeUnknownIsNoop() public {
        vm.prank(owner);
        router.setApprovedTarget(eoa, false);
        assertFalse(router.isApprovedTarget(eoa), "still not approved");
        assertEq(router.getApprovedTargetsList().length, 1, "list unchanged");
    }

    function test_rescue_sweepsFullBalance() public {
        usdc.mint(address(router), 777e6);

        vm.prank(owner);
        router.rescue(address(usdc), owner);

        assertEq(usdc.balanceOf(owner), 777e6, "swept to owner");
        assertEq(usdc.balanceOf(address(router)), 0, "router emptied");
    }

    function test_rescue_emitsEvent() public {
        usdc.mint(address(router), 777e6);

        vm.expectEmit(true, true, false, true, address(router));
        emit Rescued(address(usdc), owner, 777e6);
        vm.prank(owner);
        router.rescue(address(usdc), owner);
    }

    function testRevert_rescue_onlyOwner() public {
        usdc.mint(address(router), 777e6);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        router.rescue(address(usdc), attacker);
    }

    function test_ownable2Step_requiresAcceptance() public {
        address newOwner = address(uint160(uint256(keccak256("newOwner"))));

        vm.prank(owner);
        router.transferOwnership(newOwner);
        assertEq(router.owner(), owner, "owner unchanged until accepted");
        assertEq(router.pendingOwner(), newOwner, "pending set");

        // A non-pending address cannot accept.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        router.acceptOwnership();

        vm.prank(newOwner);
        router.acceptOwnership();
        assertEq(router.owner(), newOwner, "ownership handed over");
        assertEq(router.pendingOwner(), address(0), "pending cleared");
    }

    function testRevert_upgrade_onlyOwner() public {
        FortyAcresBatchRouter next = new FortyAcresBatchRouter();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        router.upgradeToAndCall(address(next), "");
    }

    function test_upgrade_ownerCanUpgradeAndStoragePersists() public {
        FortyAcresBatchRouter next = new FortyAcresBatchRouter();
        vm.prank(owner);
        router.upgradeToAndCall(address(next), "");

        assertTrue(router.isApprovedTarget(address(target)), "allowlist survives upgrade");
        assertTrue(router.isApprovedCaller(alice), "caller list survives upgrade");
        assertEq(router.owner(), owner, "owner survives upgrade");
    }

    // ---------------------------------------------------------- storage layout

    /**
     * Pins the RouterData slot layout the fork tests rely on when they etch the router
     * runtime at the legacy odosRouter() address and seed the allowlists with vm.store.
     * If this breaks, the fork tests are silently seeding the wrong slots.
     */
    function test_storageLayout_matchesForkEtchAssumption() public {
        uint256 base = uint256(ROUTER_SLOT);

        // approvedTargets mapping lives at P+0.
        bytes32 targetSlot = keccak256(abi.encode(address(target), base));
        assertEq(uint256(vm.load(address(router), targetSlot)), 1, "targets mapping at P+0");

        // approvedCallers mapping lives at P+3 (targets 1 slot + AddressSet 2 slots).
        bytes32 callerSlot = keccak256(abi.encode(alice, base + 3));
        assertEq(uint256(vm.load(address(router), callerSlot)), 1, "callers mapping at P+3");

        // approvedFactory is a plain address slot at P+6.
        vm.prank(owner);
        router.setApprovedFactory(address(factory));
        assertEq(
            address(uint160(uint256(vm.load(address(router), bytes32(base + 6))))),
            address(factory),
            "factory at P+6"
        );

        // Round-trip: writing the slots directly is equivalent to the setters.
        MockSwapTarget etchedTarget = new MockSwapTarget();
        vm.store(address(router), keccak256(abi.encode(address(etchedTarget), base)), bytes32(uint256(1)));
        vm.store(address(router), keccak256(abi.encode(attacker, base + 3)), bytes32(uint256(1)));
        assertTrue(router.isApprovedTarget(address(etchedTarget)), "vm.store target works");
        assertTrue(router.isApprovedCaller(attacker), "vm.store caller works");
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_swapMulti_deltaAccounting(uint256 inputAmount, uint256 outputAmount) public {
        inputAmount = bound(inputAmount, 1, 1_000e18);
        outputAmount = bound(outputAmount, 1, 1_000_000e6);

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = _swap(address(tokenA), inputAmount, address(usdc), outputAmount);

        vm.prank(alice);
        uint256[] memory outs = router.swapMulti(swaps, _one(address(usdc)), _one(outputAmount), DEADLINE);

        assertEq(outs[0], outputAmount, "delta matches fill");
        assertEq(usdc.balanceOf(alice), outputAmount, "caller paid exactly the delta");
        assertEq(usdc.balanceOf(address(router)), 0, "no residue");
        assertEq(tokenA.balanceOf(alice), 1_000e18 - inputAmount, "input debited exactly");
    }

    function testFuzz_minOutIsStrictlyEnforced(uint256 fill, uint256 minOut) public {
        fill = bound(fill, 1, 1_000e6);
        minOut = bound(minOut, 1, 2_000e6);

        FortyAcresBatchRouter.Swap[] memory swaps = new FortyAcresBatchRouter.Swap[](1);
        swaps[0] = _swap(address(tokenA), 1e18, address(usdc), fill);

        vm.prank(alice);
        if (fill < minOut) {
            vm.expectRevert(
                abi.encodeWithSelector(FortyAcresBatchRouter.InsufficientOutput.selector, address(usdc), fill, minOut)
            );
            router.swapMulti(swaps, _one(address(usdc)), _one(minOut), DEADLINE);
        } else {
            uint256[] memory outs = router.swapMulti(swaps, _one(address(usdc)), _one(minOut), DEADLINE);
            assertEq(outs[0], fill, "fill delivered");
        }
    }

    /// No unapproved address is ever a caller, regardless of what it looks like.
    function testFuzz_callerGate_rejectsArbitraryCallers(address caller) public {
        vm.assume(caller != alice);
        vm.assume(caller != address(0));

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(FortyAcresBatchRouter.CallerNotApproved.selector, caller));
        router.swapMulti(new FortyAcresBatchRouter.Swap[](0), _one(address(usdc)), _one(uint256(0)), DEADLINE);
    }
}

// ------------------------------------------------------------------- mocks

/// Behaves like a real aggregator: pulls the input it was approved for, delivers output.
contract MockSwapTarget {
    function swap(address inputToken, uint256 pullAmount, address outputToken, uint256 outAmount) external {
        if (pullAmount > 0) {
            IERC20(inputToken).transferFrom(msg.sender, address(this), pullAmount);
        }
        if (outAmount > 0) {
            MockERC20(outputToken).mint(msg.sender, outAmount);
        }
    }
}

/// Mirrors real aggregators (0x AllowanceHolder, KyberSwap): has code, reverts on
/// balanceOf, so F-1's ERC20-shape probe does not classify it as a token.
contract RevertingBalanceOfTarget {
    function balanceOf(address) external pure returns (uint256) {
        revert("no balanceOf");
    }

    function swap() external {}
}

contract RevertingTarget {
    error TargetBoom(uint256 code);

    function boom(uint256 code) external pure {
        revert TargetBoom(code);
    }
}

contract ReentrantTarget {
    FortyAcresBatchRouter internal immutable router;
    address internal immutable outputToken;
    uint256 internal immutable deadline;

    constructor(address _router, address _outputToken, uint256 _deadline) {
        router = FortyAcresBatchRouter(_router);
        outputToken = _outputToken;
        deadline = _deadline;
    }

    function reenter() external {
        address[] memory outputs = new address[](1);
        outputs[0] = outputToken;
        router.swapMulti(new FortyAcresBatchRouter.Swap[](0), outputs, new uint256[](1), deadline);
    }
}

contract MockPortfolioFactory {
    mapping(address => bool) internal portfolios;

    function setPortfolio(address account, bool isP) external {
        portfolios[account] = isP;
    }

    function isPortfolio(address account) external view returns (bool) {
        return portfolios[account];
    }
}

/// Has code but no isPortfolio; stands in for a mis-set factory address.
contract BrokenFactory {
    uint256 public sentinel;
}

/// 1% burn on every transfer. Stands in for fee-on-transfer and rebasing inputs.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("FeeOnTransfer", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0x000000000000000000000000000000000000dEaD), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// Stands in for BlackholeLoanV2 / XPharaohFacet: holds reward tokens, grants the
/// router an infinite allowance for the duration of a claim.
contract VictimLoan {
    function approveAll(address token, address spender) external {
        IERC20(token).approve(spender, type(uint256).max);
    }
}
