// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * DynamicYieldBasisLpClaiming
 *
 * Verifies harvestLpFees on the dynamic claiming facet:
 *  - happy path: pps appreciation produces surplus shares; underlying lands
 *    on the account; depositedAssetValue stays D/S-balanced.
 *  - reverts: zero slippage floor, slippage floor below 85%, no yield to
 *    harvest, yield too small.
 *  - reconcile-first invariant: out-of-band LP balance reduction (gauge fee
 *    or 1-wei rounding) is absorbed by reconcileSharesToBalance before
 *    surplus is computed -- so trackedShares is never higher than what the
 *    account actually holds at the point the harvest begins.
 * =========================================================================*/

import {DynamicYbDiamond} from "./helpers/DynamicYbDiamond.sol";

import {DynamicYieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpFacet.sol";
import {DynamicYieldBasisLpClaimingFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpClaimingFacet.sol";
import {DynamicYieldBasisLpLendingFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpLendingFacet.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockTunableYieldBasisLP} from "../../mocks/MockTunableYieldBasisLP.sol";
import {MockTunableYieldBasisGauge} from "../../mocks/MockTunableYieldBasisGauge.sol";
import {MockReentrantYieldBasisGauge} from "../../mocks/MockReentrantYieldBasisGauge.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DynamicYieldBasisLpClaimingTest is DynamicYbDiamond {
    MockTunableYieldBasisLP internal lp;
    MockTunableYieldBasisGauge internal gauge;
    address internal portfolioAccount;

    function setUp() public {
        _bootstrapTokens();
        lp = new MockTunableYieldBasisLP("ybETH", "ybETH", 18, address(underlying));
        gauge = new MockTunableYieldBasisGauge(address(lp));
        portfolioAccount = _build(address(gauge), address(lp), address(0));

        // Seed enough underlying inside the LP so withdraw can deliver.
        underlying.mint(address(lp), 1_000_000e18);
        lp.mint(user, DEPOSIT * 10);
    }

    function _floor85(uint256 pps) internal pure returns (uint256) {
        return (pps * 85) / 100;
    }

    // -----------------------------------------------------------------------
    // Slippage floor: zero rejected
    // -----------------------------------------------------------------------

    function test_harvestLpFees_revertsOnZeroFloor() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);
        lp.setPricePerShare(1.10e18);

        vm.prank(authorizedCaller);
        vm.expectRevert(bytes("Zero slippage floor"));
        DynamicYieldBasisLpClaimingFacet(portfolioAccount).harvestLpFees(0);
    }

    // -----------------------------------------------------------------------
    // Slippage floor: must be >= 85% of pps (in underlying units)
    // -----------------------------------------------------------------------

    function test_harvestLpFees_revertsWhenFloorBelow85Percent() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);
        lp.setPricePerShare(1.10e18);
        // 84% of pps -- one bps below the threshold.
        uint256 below = (lp.pricePerShare() * 84) / 100;

        vm.prank(authorizedCaller);
        vm.expectRevert(bytes("Slippage floor < 85%"));
        DynamicYieldBasisLpClaimingFacet(portfolioAccount).harvestLpFees(below);
    }

    function test_harvestLpFees_acceptsExactly85Percent() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);
        lp.setPricePerShare(1.10e18);

        // Exactly 85% must NOT revert on the floor check (will succeed if
        // yield > 0).
        uint256 floor = _floor85(lp.pricePerShare());
        vm.prank(authorizedCaller);
        DynamicYieldBasisLpClaimingFacet(portfolioAccount).harvestLpFees(floor);
    }

    // -----------------------------------------------------------------------
    // No yield: pps unchanged -> revert
    // -----------------------------------------------------------------------

    function test_harvestLpFees_revertsWhenNoYield() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);
        // pps still default 1e18 -- depositedValue == currentValue.
        uint256 floor = _floor85(lp.pricePerShare());
        vm.prank(authorizedCaller);
        vm.expectRevert(bytes("No yield to harvest"));
        DynamicYieldBasisLpClaimingFacet(portfolioAccount).harvestLpFees(floor);
    }

    // -----------------------------------------------------------------------
    // Yield too small: surplus shares rounds to 0
    // -----------------------------------------------------------------------

    function test_harvestLpFees_revertsWhenYieldTooSmall() public {
        // 1 wei of LP, then make pps 1 wei larger than 1e18. Surplus shares =
        // trackedShares * (current - deposited) / current. With trackedShares=1,
        // (curr - dep) is dust under floor division -> surplus = 0.
        lp.mint(user, 1);
        vm.startPrank(user);
        lp.approve(portfolioAccount, 1);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpFacet.deposit.selector, 1);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();

        // Bump pps by a microscopic delta so currentValue > depositedValue
        // but the surplus share count floors to zero. Deposit=1, value=1*pps/1e18.
        // pps = 1e18 + 1 -> value = 1, dep = 1. (curr - dep) = 0 -> "No yield".
        // Need pps where value rounds UP just barely. With shares=1, dep=1, we
        // can't isolate "yield too small" without "no yield". Use shares=2 and
        // pps = 1e18 + 1: value = (2*(1e18+1))/1e18 = 2. dep = 2. Still no yield.
        // With shares=2 and pps=1.5e18*1+1 wei is hard. Use shares=10 wei and
        // pps that grants 1 wei of value but 0 surplus shares.
        // Easiest: shares=100 wei, pps=1e18+1 -> value=100, dep=100 (truncation).
        // We need (curr - dep) > 0 AND (shares * (curr - dep) / curr) == 0.
        // That means curr - dep == 0 (because shares > 0 forces 0 only when
        // dividend is 0). So "yield too small" only happens when
        // basisValue _computation_ produces equal deposit and current numbers
        // but they're "almost different". The implementation's gate is the
        // require(surplusShares > 0) -- this requires basisValue(curr) >
        // basisValue(dep) BEFORE the surplus math but division still floors.
        // Achievable: use a small deposit and tiny pps growth.
        // Skip a strict mathematical reproduction and just verify that
        // depositing again with pps unchanged keeps the "no yield" branch --
        // the "yield too small" branch is functionally equivalent and would
        // be exercised in real environments where pps moves by sub-wei amounts.
        // For now, the No-yield test above guards both branches via the
        // monotone check.

        // Instead, exercise the explicit `surplusShares > 0` branch by setting
        // pps high enough that current > deposited (clears "No yield") yet
        // total tracked shares so small that surplus floors to 0.
        // Tracked = 1 wei, pps shift 1e18 -> 2e18 -> currentValue = 2, dep = 1.
        // surplus = 1 * (2 - 1) / 2 = 0 (floor).
        lp.setPricePerShare(2e18);

        uint256 floor = _floor85(lp.pricePerShare());
        vm.prank(authorizedCaller);
        vm.expectRevert(bytes("Yield too small to harvest"));
        DynamicYieldBasisLpClaimingFacet(portfolioAccount).harvestLpFees(floor);
    }

    // -----------------------------------------------------------------------
    // Happy path: pps appreciation -> surplus -> underlying delivered
    // -----------------------------------------------------------------------

    function test_harvestLpFees_happyPath_deliversUnderlying() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);

        // pps 1.0 -> 1.10 (10% fee appreciation).
        lp.setPricePerShare(1.10e18);

        uint256 floor = _floor85(lp.pricePerShare());
        uint256 underlyingPre = underlying.balanceOf(portfolioAccount);

        vm.prank(authorizedCaller);
        uint256 received = DynamicYieldBasisLpClaimingFacet(portfolioAccount).harvestLpFees(floor);

        uint256 underlyingPost = underlying.balanceOf(portfolioAccount);
        // delivered = surplusShares * pps / 1e18.
        // surplus = DEPOSIT * (1.1 - 1.0) / 1.1 = DEPOSIT * 10 / 110.
        // delivered = surplus * 1.10 = DEPOSIT * 10/110 * 110/100 = DEPOSIT * 10/100
        //           = DEPOSIT * 0.10 = 10e18 (for DEPOSIT=100e18).
        assertGt(received, 0, "received > 0");
        assertEq(underlyingPost - underlyingPre, received, "underlying credited to account");
        assertApproxEqAbs(received, 10e18, 10, "approximate 10% of DEPOSIT");

        // depositedAssetValue should now be approximately re-balanced so D/S
        // remains preserved (within rounding).
        (uint256 shares, uint256 deposited, uint256 current) =
            DynamicYieldBasisLpClaimingFacet(portfolioAccount).getDepositInfo();
        assertLt(shares, DEPOSIT, "shares reduced");
        // D/S preserved (approx). After harvest at pps=1.10:
        //   D' = D * shares' / shares, with surplus = shares - shares'.
        // Per-share basis = D/S preserved within wei rounding.
        uint256 perShareBefore = (DEPOSIT * 1e18) / DEPOSIT; // = 1e18
        uint256 perShareAfter = (deposited * 1e18) / shares;
        assertApproxEqAbs(perShareAfter, perShareBefore, 1, "per-share basis preserved");
        // current reflects new pps on the remaining shares.
        assertGt(current, 0, "current value positive");
    }

    // -----------------------------------------------------------------------
    // Reconcile-first invariant
    // -----------------------------------------------------------------------
    //
    // Out-of-band LP loss: gauge eats some LP via a withdraw shortfall.
    // harvestLpFees must call reconcileSharesToBalance BEFORE computing
    // surplus -- otherwise it would compute surplus on a tracked count that
    // exceeds actual LP on the account, and the subsequent withdraw would
    // revert or under-deliver.

    function test_harvestLpFees_reconcilesBeforeComputingSurplus() public {
        // Deposit, then stake so the gauge holds the LP.
        _setStakedMode(true);
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);

        // Configure gauge to short-deliver by 1 wei on withdraw -- simulates
        // an ERC4626 rounding eat.
        gauge.setWithdrawShortfallWei(1);

        // Out-of-band loss: burn 5 LP held on the gauge (simulate gauge fee
        // accrual that didn't update the tracked count). We do this by
        // transferring from gauge to a sink -- gauge holds DEPOSIT LP today.
        vm.prank(address(gauge));
        lp.transfer(address(0xDEAD), 5e18);

        // Bump pps to create harvestable yield.
        lp.setPricePerShare(1.10e18);

        uint256 floor = _floor85(lp.pricePerShare());

        // Pre-state: trackedShares == DEPOSIT (out-of-band loss not yet
        // reflected). Total LP available across direct + gauge.convertToAssets
        // is DEPOSIT - 5e18.
        (uint256 sharesPre, , ) =
            DynamicYieldBasisLpClaimingFacet(portfolioAccount).getDepositInfo();
        assertEq(sharesPre, DEPOSIT, "trackedShares not yet reconciled");

        vm.prank(authorizedCaller);
        DynamicYieldBasisLpClaimingFacet(portfolioAccount).harvestLpFees(floor);

        // After harvest: tracked must reflect the prior actual balance MINUS
        // any surplus that was burned -- i.e. it cannot exceed actualLp at
        // harvest entry.
        (uint256 sharesPost, , ) =
            DynamicYieldBasisLpClaimingFacet(portfolioAccount).getDepositInfo();
        assertLt(sharesPost, sharesPre, "trackedShares reduced by reconcile + surplus burn");
        // After reconcile, shares would have been DEPOSIT - 5e18 = 95e18.
        // surplus burn reduces further. So post-tracked is strictly < 95e18.
        assertLe(sharesPost, DEPOSIT - 5e18, "post-tracked <= actual LP at entry");
    }

    function test_harvestLpFees_revertsForUnauthorizedCaller() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);
        lp.setPricePerShare(1.10e18);
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        DynamicYieldBasisLpClaimingFacet(portfolioAccount).harvestLpFees(_floor85(1.10e18));
    }

    // -----------------------------------------------------------------------
    // getAvailableLpFeeYield view -- mirrors the harvest math
    // -----------------------------------------------------------------------

    function test_getAvailableLpFeeYield_zeroBeforeAppreciation() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);
        (uint256 yu, uint256 yg) =
            DynamicYieldBasisLpClaimingFacet(portfolioAccount).getAvailableLpFeeYield();
        assertEq(yu, 0, "no yield underlying");
        assertEq(yg, 0, "no yield shares");
    }

    function test_getAvailableLpFeeYield_positiveAfterAppreciation() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);
        lp.setPricePerShare(1.10e18);
        (uint256 yu, uint256 yg) =
            DynamicYieldBasisLpClaimingFacet(portfolioAccount).getAvailableLpFeeYield();
        assertGt(yu, 0, "yield in underlying > 0");
        assertGt(yg, 0, "yield in shares > 0");
    }

    // -----------------------------------------------------------------------
    // Cross-facet reentrancy: harvestLpFees -> pay must revert
    //
    // Both the claiming facet and the lending facet share the slot
    // keccak256("fortyacres.lending.reentrancy"). When harvestLpFees sets the
    // slot to 2 and a malicious gauge re-enters pay() during gauge.withdraw,
    // the lending facet's nonReentrant guard must observe the lock and revert
    // with DynamicYieldBasisLpLendingFacet.ReentrantCall. This proves the
    // guard composes across facets (mirrors ERC4626's claim->pay test).
    // -----------------------------------------------------------------------
    function test_harvestLpFees_reentrancyIntoPay_reverts() public {
        // Build a fresh diamond whose gauge is malicious. The default `lp` +
        // `gauge` from setUp are not used here because the gauge immutable
        // on each facet is baked in at construction.
        MockTunableYieldBasisLP ybLp =
            new MockTunableYieldBasisLP("ybETH2", "ybETH2", 18, address(underlying));
        MockReentrantYieldBasisGauge maliciousGauge =
            new MockReentrantYieldBasisGauge(address(ybLp));

        address account = _build(address(maliciousGauge), address(ybLp), address(0));

        // Seed the LP so its internal withdraw can deliver underlying, and
        // give the user enough LP to deposit.
        underlying.mint(address(ybLp), 1_000_000e18);
        ybLp.mint(user, DEPOSIT * 10);

        // Deposit unstaked first (factory default), then stake so all LP is
        // held by the malicious gauge. Harvest will then have to pull via
        // gauge.withdraw (zero direct LP), which is exactly where the arm
        // fires.
        _depositVia(account, MockERC20(address(ybLp)), DEPOSIT);
        vm.prank(owner_);
        portfolioFactoryConfig.setStakedGaugeMode(true);
        vm.prank(authorizedCaller);
        DynamicYieldBasisLpFacet(account).setStakedMode();

        // Borrow a small amount so the lending slot is meaningfully active
        // (pay would have real work in absence of the reentrancy guard).
        vm.startPrank(user);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpLendingFacet.borrow.selector, uint256(10e18));
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();

        // pay() does `transferFrom(msg.sender, address(this), amount)`. During
        // re-entry, msg.sender is the malicious gauge -- so fund + approve from
        // the gauge to make the transferFrom branch reachable. The reentrancy
        // guard MUST trip first, before the transferFrom executes.
        underlying.mint(address(maliciousGauge), 100e18);
        vm.prank(address(maliciousGauge));
        underlying.approve(account, type(uint256).max);

        // Generate pps appreciation so harvest has surplus shares to burn.
        ybLp.setPricePerShare(1.10e18);

        // Arm gauge: when harvestLpFees calls gauge.withdraw, the gauge
        // re-enters pay(5e18) on the same account.
        bytes memory innerCall = abi.encodeWithSelector(
            DynamicYieldBasisLpLendingFacet.pay.selector, uint256(5e18)
        );
        maliciousGauge.arm(account, innerCall);

        uint256 floor = (ybLp.pricePerShare() * 85) / 100;
        vm.prank(authorizedCaller);
        // The malicious gauge bubbles the inner ReentrantCall revert so the
        // outer harvest also aborts -- proving the shared slot composes
        // across the claiming and lending facets.
        vm.expectRevert(DynamicYieldBasisLpLendingFacet.ReentrantCall.selector);
        DynamicYieldBasisLpClaimingFacet(account).harvestLpFees(floor);
    }
}
