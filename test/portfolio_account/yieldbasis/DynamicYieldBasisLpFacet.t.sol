// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {DynamicYbDiamond} from "./helpers/DynamicYbDiamond.sol";

import {DynamicYieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpFacet.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockTunableYieldBasisLP} from "../../mocks/MockTunableYieldBasisLP.sol";
import {MockTunableYieldBasisGauge} from "../../mocks/MockTunableYieldBasisGauge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DynamicYieldBasisLpFacetTest is DynamicYbDiamond {
    MockTunableYieldBasisLP internal lp;
    MockTunableYieldBasisGauge internal gauge;
    address internal portfolioAccount;

    function setUp() public {
        _bootstrapTokens();
        lp = new MockTunableYieldBasisLP("ybETH", "ybETH", 18, address(underlying));
        gauge = new MockTunableYieldBasisGauge(address(lp));
        portfolioAccount = _build(address(gauge), address(lp), address(0));

        // Seed underlying liquidity in the LP so any future withdraw calls
        // (in other test paths) can deliver. Not strictly required here.
        underlying.mint(address(lp), 1_000_000e18);
        // Mint LP to user so they can deposit.
        lp.mint(user, DEPOSIT * 10);
    }

    // -----------------------------------------------------------------------
    // Deposit
    // -----------------------------------------------------------------------

    function test_deposit_happyPath_tracksCollateral_unstakedMode() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);

        // No auto-stake when factory flag is unstaked.
        (uint256 staked, uint256 unstaked) = DynamicYieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(staked, 0, "no gauge shares minted");
        assertEq(unstaked, DEPOSIT, "LP held on account");

        // Collateral tracked through DynamicYieldBasisCollateralManager.
        uint256 locked = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(locked, DEPOSIT, "collateral mark = shares * pps (1e18) = DEPOSIT");

        // getCollateralToken returns the LP, not the gauge.
        assertEq(
            ICollateralFacet(portfolioAccount).getCollateralToken(), address(lp),
            "collateral token is the LP, not the gauge"
        );
    }

    function test_deposit_autoStakes_whenStakedModeOn() public {
        _setStakedMode(true);
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);

        (uint256 staked, uint256 unstaked) = DynamicYieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(unstaked, 0, "all LP moved to gauge");
        assertEq(staked, DEPOSIT, "gauge shares minted 1:1");
    }

    function test_deposit_revertsOnZeroAmount() public {
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpFacet.deposit.selector, 0);
        vm.expectRevert();
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    function test_deposit_revertsWhenCallerNotPortfolioManagerMulticall() public {
        vm.prank(user);
        vm.expectRevert();
        DynamicYieldBasisLpFacet(portfolioAccount).deposit(DEPOSIT);
    }

    // -----------------------------------------------------------------------
    // Withdraw
    // -----------------------------------------------------------------------

    function test_withdraw_happyPath_pullsFromAccountLpDirectly() public {
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);

        uint256 userBefore = lp.balanceOf(user);
        _withdrawVia(portfolioAccount, DEPOSIT);
        uint256 userAfter = lp.balanceOf(user);
        assertEq(userAfter - userBefore, DEPOSIT, "full LP returned");

        // Collateral cleared.
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 0, "collateral cleared");
    }

    function test_withdraw_capsAtTrackedShares_silentlyTruncates() public {
        // Withdraw MORE than what's tracked: facet must NOT revert; it caps at
        // trackedShares. Documented behavior: amount > trackedShares -> withdraw
        // trackedShares only.
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);

        uint256 userBefore = lp.balanceOf(user);
        _withdrawVia(portfolioAccount, DEPOSIT * 5); // ask for 5x what's tracked
        uint256 userAfter = lp.balanceOf(user);

        assertEq(userAfter - userBefore, DEPOSIT, "capped at trackedShares, not the asked amount");
        assertEq(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 0,
            "all tracked collateral released"
        );
    }

    function test_withdraw_pullsFromGauge_whenDirectLpInsufficient() public {
        // Deposit, then stake everything. Direct LP balance is 0; withdraw
        // MUST unstake from the gauge to deliver.
        _setStakedMode(true);
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);

        (uint256 stakedPre, uint256 unstakedPre) = DynamicYieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(unstakedPre, 0, "precondition: no direct LP");
        assertEq(stakedPre, DEPOSIT, "precondition: all in gauge");

        uint256 userBefore = lp.balanceOf(user);
        _withdrawVia(portfolioAccount, DEPOSIT);
        uint256 userAfter = lp.balanceOf(user);

        assertEq(userAfter - userBefore, DEPOSIT, "withdrew via gauge.withdraw fallback");
        (uint256 stakedPost, uint256 unstakedPost) = DynamicYieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(stakedPost, 0, "gauge drained");
        assertEq(unstakedPost, 0, "no LP left on account");
    }

    function test_withdraw_partial_pullsFromDirectFirst_thenGauge() public {
        // Mixed state: some direct LP, some staked. Withdraw amount needs
        // both to be exercised.
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT);
        _setStakedMode(true);
        vm.prank(authorizedCaller);
        DynamicYieldBasisLpFacet(portfolioAccount).setStakedMode(); // stake whatever's on account
        // Now everything is staked. Add an unstaked top-up.
        _setStakedMode(false);
        _depositVia(portfolioAccount, MockERC20(address(lp)), DEPOSIT); // sits unstaked

        // State: 100 staked, 100 unstaked.
        (uint256 stakedPre, uint256 unstakedPre) = DynamicYieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(stakedPre, DEPOSIT, "stakedPre");
        assertEq(unstakedPre, DEPOSIT, "unstakedPre");

        // Withdraw 150: should consume all unstaked (100), then unstake 50.
        _withdrawVia(portfolioAccount, 150e18);

        (uint256 stakedPost, uint256 unstakedPost) = DynamicYieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(unstakedPost, 0, "direct LP fully consumed");
        assertEq(stakedPost, DEPOSIT - 50e18, "gauge debited by shortfall only");
    }

    function test_withdraw_revertsOnZeroAmount() public {
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(DynamicYieldBasisLpFacet.withdraw.selector, 0);
        vm.expectRevert();
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    function test_withdraw_returnsEarly_whenTrackedSharesIsZero() public {
        // No deposit ever -> trackedShares = 0. withdraw(N) hits the
        // `toWithdraw == 0` early-return branch and emits nothing / does
        // nothing. The function does NOT revert -- this is a UX choice.
        _withdrawVia(portfolioAccount, DEPOSIT);
        assertEq(ICollateralFacet(portfolioAccount).getTotalLockedCollateral(), 0, "still zero");
        assertEq(lp.balanceOf(user), DEPOSIT * 10, "user untouched");
    }

    // -----------------------------------------------------------------------
    // ICollateralFacet wiring -- dynamic manager is what the facet talks to
    // -----------------------------------------------------------------------

    function test_getTotalDebt_proxiesToDynamicManager() public {
        // No debt initially.
        assertEq(ICollateralFacet(portfolioAccount).getTotalDebt(), 0, "starts zero via dynamic mgr");
    }

    function test_getMaxLoan_returnsZeroWithNoCollateral() public view {
        (uint256 maxLoan, uint256 cap) = ICollateralFacet(portfolioAccount).getMaxLoan();
        assertEq(maxLoan, 0, "no collateral -> no headroom");
        assertEq(cap, 0, "no collateral -> no cap");
    }
}
