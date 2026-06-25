// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/*
 * ==========================================================================
 * DynamicYieldBasisCollateralManager -- repay must never revert on paused src
 * ==========================================================================
 *
 * Same asymmetry as the regular YB manager, validated for the Dynamic
 * (vault-read-debt) variant. The repay path (decreaseTotalDebt ->
 * _snapshotIfNeededRepay) wraps both revert-prone reads:
 *   (a) gauge ratchet read  : _actualLpRepaySafe -> gauge.convertToAssets
 *   (b) YB market price read : _resolveCollateralValueRepaySafe ->
 *                              lp.pricePerShare + lp.preview_withdraw
 * A paused source skips the snapshot and the repay proceeds; a borrow under
 * the same pause still reverts (strict reads on the borrow path).
 *
 * Reuses the DynamicYbDiamond harness builder with pausable LP + gauge mocks.
 * ==========================================================================
 */

import {DynamicYbDiamond} from "./helpers/DynamicYbDiamond.sol";

import {DynamicYieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpFacet.sol";
import {DynamicYieldBasisLpLendingFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpLendingFacet.sol";

import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockPausableYieldBasisLP} from "../../mocks/MockPausableYieldBasisLP.sol";
import {MockPausableYieldBasisGauge} from "../../mocks/MockPausableYieldBasisGauge.sol";
import {ILendingPool} from "../../../src/interfaces/ILendingPool.sol";

contract DynamicYieldBasisRepayPreviewRevertTest is DynamicYbDiamond {
    MockPausableYieldBasisLP internal lp;
    MockPausableYieldBasisGauge internal gauge;
    address internal portfolioAccount;

    uint256 internal constant BORROW_AMOUNT = 30e18; // < 70% of 100e18 deposit

    function setUp() public {
        _bootstrapTokens();
        lp = new MockPausableYieldBasisLP("ybETH", "ybETH", 18, address(underlying));
        gauge = new MockPausableYieldBasisGauge(address(lp));
        portfolioAccount = _build(address(gauge), address(lp), address(0));

        // Seed the LP mock with underlying so gauge/LP withdraws can deliver.
        underlying.mint(address(lp), 1_000_000e18);
        lp.mint(user, DEPOSIT * 10);
    }

    // ============ helpers ============

    function _borrow(uint256 amount) internal {
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpLendingFacet.borrow.selector, amount);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    function _borrowExpectRevert(uint256 amount) internal {
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpLendingFacet.borrow.selector, amount);
        vm.expectRevert(bytes("paused"));
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    function _pay(uint256 amount) internal {
        vm.startPrank(user);
        underlying.approve(portfolioAccount, amount);
        DynamicYieldBasisLpLendingFacet(portfolioAccount).pay(amount);
        vm.stopPrank();
    }

    function _stake() internal {
        // Flip the protocol directive, then sweep this account into it.
        _setStakedMode(true);
        vm.prank(authorizedCaller);
        DynamicYieldBasisLpFacet(portfolioAccount).setStakedMode();
    }

    function _debt() internal view returns (uint256) {
        return ICollateralFacet(portfolioAccount).getTotalDebt();
    }

    // ========================================================================
    // (a) Paused YB MARKET (pricePerShare / preview_withdraw revert), unstaked
    // ========================================================================

    function test_repay_succeeds_whenYbMarketPaused_unstaked() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);
        vm.roll(block.number + 1);
        _borrow(BORROW_AMOUNT);
        vm.roll(block.number + 1);

        uint256 debtBefore = _debt();
        assertEq(debtBefore, BORROW_AMOUNT, "debt is the borrow before repay");

        lp.setPaused(true);
        vm.expectRevert(bytes("paused"));
        lp.pricePerShare();

        uint256 amountPaid = 10e18;
        underlying.mint(user, amountPaid);
        _pay(amountPaid);

        uint256 debtAfter = _debt();
        assertLt(debtAfter, debtBefore, "repay must reduce debt even when YB market read reverts");
        assertEq(debtAfter, debtBefore - amountPaid, "debt drops by exactly the repaid amount");
        assertEq(
            ILendingPool(address(lendingVault)).getDebtBalance(portfolioAccount),
            debtBefore - amountPaid,
            "pool debt drops by exactly the repaid amount"
        );
    }

    function test_borrow_reverts_whenYbMarketPaused_unstaked() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);
        vm.roll(block.number + 1);
        _borrow(BORROW_AMOUNT);
        vm.roll(block.number + 1);

        lp.setPaused(true);
        _borrowExpectRevert(1e18);

        assertEq(_debt(), BORROW_AMOUNT, "borrow must not land when YB market is paused");
    }

    // ========================================================================
    // (b) Paused GAUGE (convertToAssets reverts), staked
    // ========================================================================

    function test_repay_succeeds_whenGaugePaused_staked() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);
        _stake();

        (uint256 staked, uint256 unstaked) = DynamicYieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT, "LP staked into gauge");
        assertEq(unstaked, 0, "no direct LP");

        vm.roll(block.number + 1);
        _borrow(BORROW_AMOUNT);
        vm.roll(block.number + 1);

        uint256 debtBefore = _debt();
        assertEq(debtBefore, BORROW_AMOUNT, "debt is the borrow before repay");

        gauge.setConvertPaused(true);
        vm.expectRevert(bytes("paused"));
        gauge.convertToAssets(1);

        uint256 amountPaid = 10e18;
        underlying.mint(user, amountPaid);
        _pay(amountPaid);

        uint256 debtAfter = _debt();
        assertLt(debtAfter, debtBefore, "repay must reduce debt even when gauge read reverts");
        assertEq(debtAfter, debtBefore - amountPaid, "debt drops by exactly the repaid amount");
        assertEq(
            ILendingPool(address(lendingVault)).getDebtBalance(portfolioAccount),
            debtBefore - amountPaid,
            "pool debt drops by exactly the repaid amount"
        );
    }

    function test_borrow_reverts_whenGaugePaused_staked() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);
        _stake();

        vm.roll(block.number + 1);
        _borrow(BORROW_AMOUNT);
        vm.roll(block.number + 1);

        gauge.setConvertPaused(true);
        _borrowExpectRevert(1e18);

        assertEq(_debt(), BORROW_AMOUNT, "borrow must not land when gauge is paused");
    }
}
