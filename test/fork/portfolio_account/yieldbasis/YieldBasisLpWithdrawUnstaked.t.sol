// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {YieldBasisLpFacet} from "../../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {ERC4626CollateralManager} from "../../../../src/facets/account/erc4626/ERC4626CollateralManager.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {DeployPortfolioFactoryConfig} from "../../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {IYieldBasisGauge} from "../../../../src/interfaces/IYieldBasisGauge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILendingPool} from "../../../../src/interfaces/ILendingPool.sol";

contract MockLendingPool is ILendingPool {
    address public immutable _lendingAsset;
    address public immutable _lendingVault;
    address public _portfolioFactory;

    constructor(address lendingAsset_, address lendingVault_) {
        _lendingAsset = lendingAsset_;
        _lendingVault = lendingVault_;
    }

    function setPortfolioFactory(address factory) external { _portfolioFactory = factory; }
    function getPortfolioFactory() external view returns (address) { return _portfolioFactory; }
    function borrowFromPortfolio(uint256) external pure returns (uint256) { return 0; }
    function payFromPortfolio(uint256 totalPayment, uint256) external pure returns (uint256) { return totalPayment; }
    function lendingAsset() external view returns (address) { return _lendingAsset; }
    function lendingVault() external view returns (address) { return _lendingVault; }
    function activeAssets() external pure returns (uint256) { return 0; }
    function depositRewards(uint256) external {}
    function setActiveAssets(uint256) external {}
    function getDebtBalance(address) external pure returns (uint256) { return 0; }
    function getEffectiveDebtBalance(address) external pure returns (uint256) { return 0; }
}

contract MockVault {
    address public immutable _asset;
    constructor(address asset_) { _asset = asset_; }
    function asset() external view returns (address) { return _asset; }
}

/**
 * @title YieldBasisLpWithdrawUnstakedTest
 * @dev Fork tests verifying that withdraw() correctly removes collateral
 *      when position is fully or partially unstaked from the gauge.
 */
contract YieldBasisLpWithdrawUnstakedTest is Test {
    address public constant YB = 0x01791F726B4103694969820be083196cC7c045fF;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant WBTC_GAUGE = 0xbc56e3edB67b56d598aCE07668b138815F45d7aa;
    address public constant WBTC_LP = 0xfBF3C16676055776Ab9B286492D8f13e30e2E763;
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;

    address public user = address(0x40ac2e);
    address public authorizedCaller = address(0xaaaaa);

    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    PortfolioFactoryConfig public portfolioFactoryConfig;
    address public portfolioAccount;

    IYieldBasisGauge public gauge = IYieldBasisGauge(WBTC_GAUGE);
    IERC20 public lpToken = IERC20(WBTC_LP);

    function setUp() public {
        uint256 fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);

        vm.startPrank(DEPLOYER);

        portfolioManager = new PortfolioManager(DEPLOYER);

        (portfolioFactory,) = portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("yb-lp-withdraw-test")))
        );

        DeployPortfolioFactoryConfig configDeployer = new DeployPortfolioFactoryConfig();
        (portfolioFactoryConfig,,,) = configDeployer.deploy(address(portfolioFactory), DEPLOYER);

        MockVault mockVault = new MockVault(USDC);
        MockLendingPool mockLendingPool = new MockLendingPool(USDC, address(mockVault));
        mockLendingPool.setPortfolioFactory(address(portfolioFactory));
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));
        portfolioFactoryConfig.setLoanContract(address(mockLendingPool));
        deal(USDC, address(mockVault), 1_000_000 * 1e6);

        YieldBasisLpFacet lpFacet = new YieldBasisLpFacet(
            address(portfolioFactory),
            WBTC_GAUGE,
            YB,
            WBTC
        );
        bytes4[] memory lpSelectors = new bytes4[](9);
        lpSelectors[0] = YieldBasisLpFacet.deposit.selector;
        lpSelectors[1] = YieldBasisLpFacet.withdraw.selector;
        lpSelectors[2] = YieldBasisLpFacet.unstake.selector;
        lpSelectors[3] = YieldBasisLpFacet.stake.selector;
        lpSelectors[4] = YieldBasisLpFacet.getStakingState.selector;
        lpSelectors[5] = ICollateralFacet.getTotalLockedCollateral.selector;
        lpSelectors[6] = ICollateralFacet.getTotalDebt.selector;
        lpSelectors[7] = ICollateralFacet.getMaxLoan.selector;
        lpSelectors[8] = ICollateralFacet.enforceCollateralRequirements.selector;
        FacetRegistry facetRegistry = portfolioFactory.facetRegistry();
        facetRegistry.registerFacet(address(lpFacet), lpSelectors, "YieldBasisLpFacet");

        portfolioManager.setAuthorizedCaller(authorizedCaller, true);

        vm.stopPrank();

        portfolioAccount = portfolioFactory.createAccount(user);

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    // ── Helpers ──

    function _depositViaMulticall(uint256 amount) internal {
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount);
        vm.prank(user);
        portfolioManager.multicall(calldatas, factories);
    }

    function _withdrawViaMulticall(uint256 amount) internal {
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, amount);
        vm.prank(user);
        portfolioManager.multicall(calldatas, factories);
    }

    function _unstakeViaAuthorized(uint256 shares) internal {
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).unstake(shares);
    }

    /// @dev After the deposit refactor, deposit() no longer auto-stakes into the gauge —
    ///      LP sits unstaked on the portfolio account. Tests that exercise gauge state
    ///      must explicitly stake via the authorized-caller admin path.
    function _stakeViaAuthorized(uint256 amount) internal {
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).stake(amount);
    }

    // ── Tests: Happy Path ──

    /// @notice Withdraw when the position is fully unstaked (the default post-deposit state
    ///         under the current facet): collateral must be zeroed.
    function testWithdrawFullyUnstaked_collateralCleared() public {
        uint256 depositAmount = 1 ether;
        deal(WBTC_LP, user, depositAmount);
        vm.prank(user);
        lpToken.approve(portfolioAccount, depositAmount);

        _depositViaMulticall(depositAmount);

        // Under current semantics, deposit() pulls LP onto the account without staking.
        // Verify we're in the fully-unstaked default state (NOT the pre-refactor staked state).
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(staked, 0, "Deposit should not auto-stake into gauge");
        assertEq(unstaked, depositAmount, "Full LP amount must sit unstaked on account");

        uint256 collateralBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(collateralBefore, 0, "Should have collateral after deposit");
        console.log("Collateral after deposit:", collateralBefore);

        // Withdraw the entire unstaked LP amount — withdraw() should not touch the gauge
        // because the full amount is already on the account.
        _withdrawViaMulticall(unstaked);

        // Collateral MUST be zero after full withdrawal
        uint256 collateralAfterWithdraw = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfterWithdraw, 0, "Collateral must be zero after full withdrawal");
        console.log("Collateral after withdraw:", collateralAfterWithdraw);

        // LP should be with the user
        uint256 userLpBalance = lpToken.balanceOf(user);
        assertEq(userLpBalance, depositAmount, "User should receive exactly the deposited LP back");

        // Gauge state must remain clean — no stray shares on the account
        (staked, unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(staked, 0, "No gauge shares after fully-unstaked withdraw");
        assertEq(unstaked, 0, "No residual LP on account after full withdraw");
    }

    /// @notice Partial withdraw from fully unstaked position — collateral should drop by ~50%
    function testWithdrawPartialFromUnstaked_collateralReduced() public {
        uint256 depositAmount = 2 ether;
        deal(WBTC_LP, user, depositAmount);
        vm.prank(user);
        lpToken.approve(portfolioAccount, depositAmount);

        _depositViaMulticall(depositAmount);

        // Post-deposit: position is fully unstaked (no gauge interaction on deposit).
        (, uint256 unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(unstaked, depositAmount, "Precondition: full LP sits unstaked on account");
        uint256 collateralFull = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();

        // Withdraw half — should be serviced entirely from unstaked LP, no gauge interaction.
        uint256 halfAmount = unstaked / 2;
        _withdrawViaMulticall(halfAmount);

        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        // Strengthened assertion: collateral should be approximately 50% of the full amount
        // (within 1% tolerance to account for rounding in share-to-asset conversions)
        assertApproxEqRel(collateralAfter, collateralFull / 2, 0.01e18, "Collateral should be ~50% after half withdrawal");
        console.log("Collateral full:", collateralFull, "after half withdraw:", collateralAfter);

        // Remaining LP on account must equal the other half (no gauge leakage).
        (, uint256 unstakedAfter) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(unstakedAfter, unstaked - halfAmount, "Remaining unstaked LP must match");
    }

    /// @notice Withdraw from mixed position (some staked, some unstaked).
    ///         Under current semantics we must explicitly stake half to create the mixed state.
    function testWithdrawFromMixed_collateralCleared() public {
        uint256 depositAmount = 2 ether;
        deal(WBTC_LP, user, depositAmount);
        vm.prank(user);
        lpToken.approve(portfolioAccount, depositAmount);

        _depositViaMulticall(depositAmount);

        // Explicitly stake half of the deposited LP into the gauge so we have a
        // genuine mixed-state position for the withdraw path to exercise.
        uint256 halfDeposit = depositAmount / 2;
        _stakeViaAuthorized(halfDeposit);

        (uint256 stakedAfter, uint256 unstakedAfter) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertGt(stakedAfter, 0, "Should have gauge shares after stake");
        assertEq(unstakedAfter, depositAmount - halfDeposit, "Half remains unstaked on account");

        // Withdraw everything (unstaked + staked portions). withdraw() should drain the
        // unstaked LP first, then redeem the shortfall from the gauge.
        uint256 totalLpAvailable = unstakedAfter + gauge.convertToAssets(stakedAfter);
        _withdrawViaMulticall(totalLpAvailable);

        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertLe(collateralAfter, 1, "Collateral must be zero (or dust) after full withdrawal");

        // User received LP, account drained
        assertGt(lpToken.balanceOf(user), 0, "User should receive LP");
        (uint256 stakedFinal, uint256 unstakedFinal) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(stakedFinal, 0, "No gauge shares after full withdraw");
        assertEq(unstakedFinal, 0, "No residual LP after full withdraw");
    }

    /// @notice Withdraw from a fully-staked position exercises the gauge-redeem branch of
    ///         withdraw(). Under current semantics we must explicitly stake after deposit.
    function testWithdrawFromStaked_collateralCleared() public {
        uint256 depositAmount = 1 ether;
        deal(WBTC_LP, user, depositAmount);
        vm.prank(user);
        lpToken.approve(portfolioAccount, depositAmount);

        _depositViaMulticall(depositAmount);

        // Move the full LP into the gauge so withdraw() has to redeem shares.
        _stakeViaAuthorized(depositAmount);

        (uint256 staked, uint256 unstakedAfterStake) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertGt(staked, 0, "Should have gauge shares after explicit stake");
        assertEq(unstakedAfterStake, 0, "No unstaked LP after full stake");

        uint256 collateralBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(collateralBefore, 0, "Should have collateral");

        // Get the actual LP amount the gauge will return for our shares
        uint256 withdrawableLP = gauge.convertToAssets(staked);

        // Withdraw directly from staked (requires gauge.withdraw path inside withdraw())
        _withdrawViaMulticall(withdrawableLP);

        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertLe(collateralAfter, 1, "Collateral must be zero (or dust) after full withdrawal");

        uint256 userBalance = lpToken.balanceOf(user);
        assertGt(userBalance, 0, "User should have LP tokens");

        (uint256 stakedFinal, uint256 unstakedFinal) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(stakedFinal, 0, "No gauge shares after fully draining");
        assertEq(unstakedFinal, 0, "No residual LP on account");
    }

    // ── Tests: Revert / Error Cases ──

    /// @notice withdraw(0) must revert with "Zero amount"
    function testRevert_withdraw_zeroAmount() public {
        uint256 depositAmount = 1 ether;
        deal(WBTC_LP, user, depositAmount);
        vm.prank(user);
        lpToken.approve(portfolioAccount, depositAmount);
        _depositViaMulticall(depositAmount);

        // Attempting to withdraw 0 should revert
        // The revert bubbles up through PortfolioManager.multicall which re-throws
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, 0);

        vm.prank(user);
        vm.expectRevert("Zero amount");
        portfolioManager.multicall(calldatas, factories);
    }

    /// @notice Withdrawing more LP than total available (staked + unstaked) must revert
    function testRevert_withdraw_exceedsAvailableBalance() public {
        uint256 depositAmount = 1 ether;
        deal(WBTC_LP, user, depositAmount);
        vm.prank(user);
        lpToken.approve(portfolioAccount, depositAmount);
        _depositViaMulticall(depositAmount);

        // Try to withdraw 10x more than deposited — this must revert
        // The removeCollateral call will fail with "Insufficient collateral shares"
        // because the gauge doesn't have that many shares to preview
        uint256 excessAmount = depositAmount * 10;

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, excessAmount);

        vm.prank(user);
        vm.expectRevert(); // Reverts in gauge.previewWithdraw or removeCollateral
        portfolioManager.multicall(calldatas, factories);
    }

    // ── Tests: Access Control ──

    /// @notice Calling withdraw() directly on the portfolio account (bypassing PortfolioManager.multicall)
    ///         must revert due to onlyPortfolioManagerMulticall modifier
    function testRevert_withdraw_directCallNotViaMulticall() public {
        uint256 depositAmount = 1 ether;
        deal(WBTC_LP, user, depositAmount);
        vm.prank(user);
        lpToken.approve(portfolioAccount, depositAmount);
        _depositViaMulticall(depositAmount);

        // Post-deposit the LP is already unstaked on the account (deposit no longer
        // auto-stakes), so we can proceed directly to the direct-call revert check.
        (, uint256 unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(unstaked, depositAmount, "Deposit should leave LP unstaked on account");

        // Direct call as user — must revert (bare require, no message)
        vm.prank(user);
        vm.expectRevert();
        YieldBasisLpFacet(portfolioAccount).withdraw(unstaked);
    }

    /// @notice Calling unstake() from a non-authorized caller must revert
    ///         due to onlyAuthorizedCaller modifier. We must first explicitly stake
    ///         so that the attempted unstake hits the access-control check rather than
    ///         the _gauge.redeem(0) path.
    function testRevert_unstake_unauthorizedCaller() public {
        uint256 depositAmount = 1 ether;
        deal(WBTC_LP, user, depositAmount);
        vm.prank(user);
        lpToken.approve(portfolioAccount, depositAmount);
        _depositViaMulticall(depositAmount);

        // Explicitly stake so there are real gauge shares to attempt unstaking.
        _stakeViaAuthorized(depositAmount);

        (uint256 staked,) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertGt(staked, 0, "Precondition: gauge shares must exist");

        // Random address that is NOT the authorizedCaller
        address randomCaller = address(0xdead);
        assertFalse(
            portfolioManager.isAuthorizedCaller(randomCaller),
            "randomCaller should not be authorized"
        );

        // Direct call from unauthorized address — must revert at onlyAuthorizedCaller
        // (bare require, no message), BEFORE reaching any gauge logic.
        vm.prank(randomCaller);
        vm.expectRevert();
        YieldBasisLpFacet(portfolioAccount).unstake(staked);
    }

    /// @notice Even the portfolio owner cannot call unstake() — only authorizedCaller can.
    ///         We must first explicitly stake to ensure the revert is from the access-control
    ///         modifier and not a zero-shares redeem.
    function testRevert_unstake_ownerIsNotAuthorized() public {
        uint256 depositAmount = 1 ether;
        deal(WBTC_LP, user, depositAmount);
        vm.prank(user);
        lpToken.approve(portfolioAccount, depositAmount);
        _depositViaMulticall(depositAmount);

        // Stake explicitly so gauge shares exist for the unstake call.
        _stakeViaAuthorized(depositAmount);

        (uint256 staked,) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertGt(staked, 0, "Precondition: gauge shares must exist");

        // The portfolio owner (user) is not the authorizedCaller
        assertFalse(
            portfolioManager.isAuthorizedCaller(user),
            "user should not be an authorized caller"
        );

        vm.prank(user);
        vm.expectRevert();
        YieldBasisLpFacet(portfolioAccount).unstake(staked);
    }

    /// @notice unstake(0) should revert with "Zero amount"
    function testRevert_unstake_zeroShares() public {
        uint256 depositAmount = 1 ether;
        deal(WBTC_LP, user, depositAmount);
        vm.prank(user);
        lpToken.approve(portfolioAccount, depositAmount);
        _depositViaMulticall(depositAmount);

        // Even the authorizedCaller cannot unstake 0 shares
        vm.prank(authorizedCaller);
        vm.expectRevert("Zero amount");
        YieldBasisLpFacet(portfolioAccount).unstake(0);
    }
}
