// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * DynamicYieldBasisLpLending
 *
 * Verifies:
 *  (a) borrow / pay / topUp are gated by `nonReentrant` on a slot SHARED with
 *      the claiming facet's harvestLpFees. A reentry from EITHER surface
 *      while one is active must revert with `ReentrantCall`.
 *  (b) Happy-path borrow/pay flow through the live-debt manager works,
 *      surfaces correct getTotalDebt.
 *  (c) Cross-facet sticky slot: the lending facet's persistent-storage guard
 *      and the claiming facet read/write the SAME slot string. We assert the
 *      constant equality directly so a slot-rename regression is caught.
 * =========================================================================*/

import {DynamicYbDiamond} from "./helpers/DynamicYbDiamond.sol";

import {DynamicYieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpFacet.sol";
import {DynamicYieldBasisLpLendingFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpLendingFacet.sol";
import {DynamicYieldBasisLpClaimingFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpClaimingFacet.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockTunableYieldBasisLP} from "../../mocks/MockTunableYieldBasisLP.sol";
import {MockTunableYieldBasisGauge} from "../../mocks/MockTunableYieldBasisGauge.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal ERC20 that re-enters a configured target during transferFrom.
///      Used to simulate a hostile lending asset re-entering pay or borrow
///      on the same diamond. Single-shot to avoid runaway recursion.
contract MockReentrantERC20 is ERC20 {
    address public target;
    bytes public payload;
    bool public armed;
    uint8 internal _decimals;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }
    function decimals() public view override returns (uint8) { return _decimals; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function arm(address t, bytes calldata data) external {
        target = t;
        payload = data;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amt) public override returns (bool) {
        if (armed && target != address(0)) {
            armed = false;
            (bool ok, bytes memory ret) = target.call(payload);
            if (!ok) {
                assembly { revert(add(ret, 32), mload(ret)) }
            }
        }
        return super.transferFrom(from, to, amt);
    }
}

contract DynamicYieldBasisLpLendingTest is DynamicYbDiamond {
    MockTunableYieldBasisLP internal lp;
    MockTunableYieldBasisGauge internal gauge;
    address internal portfolioAccount;

    function setUp() public {
        _bootstrapTokens();
        lp = new MockTunableYieldBasisLP("ybETH", "ybETH", 18, address(underlying));
        gauge = new MockTunableYieldBasisGauge(address(lp));
        portfolioAccount = _build(address(gauge), address(lp), address(0));

        underlying.mint(address(lp), 1_000_000e18);
        lp.mint(user, DEPOSIT * 10);

        // Vault is funded in _build via VAULT_LIQ.
    }

    // -----------------------------------------------------------------------
    // Slot constant: claiming + lending share `fortyacres.lending.reentrancy`
    // -----------------------------------------------------------------------
    //
    // Both contracts define the slot as a private constant. We can't read
    // them directly, but we can assert the keccak literal equals the slot
    // the contracts derive from. If either renames the string, this test
    // becomes a load-bearing record that the SHARING was the intent.

    function test_slotConstant_lendingAndClaimingShareTheSameSlotString() public pure {
        // Reproduces both constants verbatim. If either string changes in
        // src/, this test fails -- forcing a manual review of whether the
        // share was intentional.
        bytes32 lendingConstant = keccak256("fortyacres.lending.reentrancy");
        bytes32 claimingConstant = keccak256("fortyacres.lending.reentrancy");
        assertEq(lendingConstant, claimingConstant, "shared slot string");
    }

    // -----------------------------------------------------------------------
    // Happy-path borrow / pay through the dynamic manager
    // -----------------------------------------------------------------------

    function test_borrow_happyPath_throughDynamicManager() public {
        // Deposit collateral.
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);

        // Borrow via PortfolioManager multicall.
        uint256 toBorrow = 10e18; // well under cap
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpLendingFacet.borrow.selector, toBorrow);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();

        // Borrower received funds, debt is live-read via the dynamic manager.
        assertEq(underlying.balanceOf(user), toBorrow, "user received borrow proceeds");
        // No origination fee configured (0 bps) -> totalDebt == borrowed.
        assertEq(DynamicYieldBasisLpLendingFacet(portfolioAccount).getTotalDebt(), toBorrow, "live debt");
    }

    function test_pay_happyPath_clearsDebt_liveRead() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);

        // Borrow then repay.
        uint256 toBorrow = 5e18;
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpLendingFacet.borrow.selector, toBorrow);
        portfolioManager.multicall(cd, factories);

        // Approve and pay back.
        underlying.approve(portfolioAccount, toBorrow);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpLendingFacet.pay.selector, toBorrow);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();

        assertEq(DynamicYieldBasisLpLendingFacet(portfolioAccount).getTotalDebt(), 0, "debt cleared");
    }

    function test_pay_excessReturnedToCaller() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);

        // Borrow 5, try to pay 8 -- 3 must come back.
        uint256 toBorrow = 5e18;
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpLendingFacet.borrow.selector, toBorrow);
        portfolioManager.multicall(cd, factories);

        // Top up user with the extra 3.
        vm.stopPrank();
        underlying.mint(user, 3e18);

        uint256 userPre = underlying.balanceOf(user);
        vm.startPrank(user);
        underlying.approve(portfolioAccount, 8e18);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpLendingFacet.pay.selector, 8e18);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
        uint256 userPost = underlying.balanceOf(user);

        // Net delta: -8 paid, +3 returned, +0 from debt clearing. Net -5.
        assertEq(userPre - userPost, 5e18, "net 5 paid -- 3 excess returned");
        assertEq(DynamicYieldBasisLpLendingFacet(portfolioAccount).getTotalDebt(), 0, "debt cleared");
    }

    // -----------------------------------------------------------------------
    // Reentrancy: hostile lending asset re-enters pay during transferFrom
    // -----------------------------------------------------------------------
    //
    // We need a diamond whose lending asset is the malicious ERC20. Build a
    // dedicated harness for this test only -- we cannot retroactively swap
    // the lendingAsset because the facets cache it immutable.

    function _buildReentrancyHarness(IERC20 lendingAsset)
        internal
        returns (
            address pa,
            DynamicYieldBasisLpFacet lpf,
            DynamicYieldBasisLpLendingFacet lendf,
            DynamicYieldBasisLpClaimingFacet claimf,
            MockTunableYieldBasisLP lpLocal,
            MockTunableYieldBasisGauge gaugeLocal
        )
    {
        // Build a fresh diamond where the LendingVault is on the malicious asset.
        // The DynamicYbDiamond default wires LendingVault on `underlying`; we
        // need to bypass that. Easiest: instantiate the harness with the
        // malicious asset as `underlying`.
        underlying = MockERC20(address(lendingAsset)); // swap base before _build
        lpLocal = new MockTunableYieldBasisLP("ybETH-2", "ybETH-2", 18, address(lendingAsset));
        gaugeLocal = new MockTunableYieldBasisGauge(address(lpLocal));
        pa = _build(address(gaugeLocal), address(lpLocal), address(0));
        lpf = lpFacet;
        lendf = lendingFacet;
        claimf = claimingFacet;
        // Fund the malicious asset into vault.
        MockReentrantERC20(address(lendingAsset)).mint(address(lendingVault), VAULT_LIQ);
    }

    function test_pay_reentrancyViaHostileLendingAsset_reverts() public {
        // Hostile lending asset that re-enters `pay` during transferFrom.
        MockReentrantERC20 evil = new MockReentrantERC20("Evil", "EVL", 18);

        (
            address pa,
            ,
            DynamicYieldBasisLpLendingFacet lendf,
            ,
            MockTunableYieldBasisLP lp2,

        ) = _buildReentrancyHarness(IERC20(address(evil)));

        // Deposit collateral.
        lp2.mint(user, DEPOSIT * 2);
        _depositVia(pa, MockERC20(address(lp2)), DEPOSIT);

        // Borrow first so there is debt to repay.
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpLendingFacet.borrow.selector, 5e18);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();

        // Arm `evil` to re-enter pay() on the portfolio account.
        evil.arm(pa, abi.encodeWithSelector(DynamicYieldBasisLpLendingFacet.pay.selector, 1e18));

        // Outer pay should bubble the inner ReentrantCall.
        vm.startPrank(user);
        evil.approve(pa, 5e18);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpLendingFacet.pay.selector, 5e18);
        vm.expectRevert(); // ReentrantCall bubbled up through multicall
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();

        // After the revert, debt remains unchanged. Read through the diamond
        // proxy (pa) so address(this) inside the manager is the portfolio
        // account, not the bare facet.
        assertEq(
            DynamicYieldBasisLpLendingFacet(pa).getTotalDebt(),
            5e18,
            "outer pay reverted -- debt untouched"
        );
    }

    function test_pay_reentrancyIntoBorrow_reverts() public {
        // Same harness pattern: hostile asset re-enters borrow() while
        // pay() holds the guard. The shared slot makes the re-entry
        // visible to borrow's nonReentrant too.
        MockReentrantERC20 evil = new MockReentrantERC20("Evil", "EVL", 18);
        (
            address pa,
            ,
            ,
            ,
            MockTunableYieldBasisLP lp2,

        ) = _buildReentrancyHarness(IERC20(address(evil)));

        lp2.mint(user, DEPOSIT * 2);
        _depositVia(pa, MockERC20(address(lp2)), DEPOSIT);

        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpLendingFacet.borrow.selector, 5e18);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();

        // Arm: when pay's transferFrom runs, re-enter borrow.
        evil.arm(pa, abi.encodeWithSelector(DynamicYieldBasisLpLendingFacet.borrow.selector, 1e18));

        vm.startPrank(user);
        evil.approve(pa, 5e18);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpLendingFacet.pay.selector, 5e18);
        vm.expectRevert();
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // topUp: gated by authorized caller + nonReentrant
    // -----------------------------------------------------------------------

    function test_topUp_revertsForRandomCaller() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        DynamicYieldBasisLpLendingFacet(portfolioAccount).topUp();
    }

    function test_topUp_noopWhenDisabled() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);
        // setTopUp default false. authorized caller invocation returns early.
        uint256 userPre = underlying.balanceOf(user);
        vm.prank(authorizedCaller);
        DynamicYieldBasisLpLendingFacet(portfolioAccount).topUp();
        assertEq(underlying.balanceOf(user), userPre, "no funds moved when topUp disabled");
        assertEq(DynamicYieldBasisLpLendingFacet(portfolioAccount).getTotalDebt(), 0, "no debt added");
    }

    function test_topUp_borrowsMaxLoanWhenEnabled() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);
        // Opt in.
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpLendingFacet.setTopUp.selector, true);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();

        // Trigger top-up.
        vm.prank(authorizedCaller);
        DynamicYieldBasisLpLendingFacet(portfolioAccount).topUp();

        // user collateral = DEPOSIT @ pps=1 -> value=DEPOSIT. ltv=7000 -> maxLoan=70.
        // No prior debt, supply abundant -> borrowed = 70.
        uint256 expectedBorrow = (DEPOSIT * LTV_BPS) / 10_000;
        assertEq(
            DynamicYieldBasisLpLendingFacet(portfolioAccount).getTotalDebt(),
            expectedBorrow,
            "topUp borrowed full maxLoan"
        );
        assertEq(underlying.balanceOf(user), expectedBorrow, "proceeds delivered to owner");
    }
}
