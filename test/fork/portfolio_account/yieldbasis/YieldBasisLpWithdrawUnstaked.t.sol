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
            YB
        );
        bytes4[] memory lpSelectors = new bytes4[](9);
        lpSelectors[0] = YieldBasisLpFacet.deposit.selector;
        lpSelectors[1] = YieldBasisLpFacet.withdraw.selector;
        lpSelectors[2] = YieldBasisLpFacet.unstake.selector;
        lpSelectors[3] = YieldBasisLpFacet.restake.selector;
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

    // ── Tests: Happy Path ──

    /// @notice Withdraw after full unstake: collateral must be zeroed
    function testWithdrawFullyUnstaked_collateralCleared() public {
        uint256 depositAmount = 1 ether;
        deal(WBTC_LP, portfolioAccount, depositAmount);

        _depositViaMulticall(depositAmount);

        // Verify staked
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertGt(staked, 0, "Should have gauge shares after deposit");
        assertEq(unstaked, 0, "No unstaked LP after deposit");

        uint256 collateralBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(collateralBefore, 0, "Should have collateral after deposit");
        console.log("Collateral after deposit:", collateralBefore);

        // Unstake everything (admin action — doesn't touch collateral tracking)
        _unstakeViaAuthorized(staked);

        (staked, unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(staked, 0, "Should have 0 gauge shares after unstake");
        assertGt(unstaked, 0, "Should have unstaked LP after unstake");

        // Collateral should still be tracked (unstake doesn't modify it)
        uint256 collateralAfterUnstake = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfterUnstake, collateralBefore, "Collateral unchanged after unstake");

        // Now withdraw — this is the critical test
        _withdrawViaMulticall(unstaked);

        // Collateral MUST be zero after full withdrawal
        uint256 collateralAfterWithdraw = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfterWithdraw, 0, "Collateral must be zero after full withdrawal");
        console.log("Collateral after withdraw:", collateralAfterWithdraw);

        // LP should be with the user
        uint256 userLpBalance = lpToken.balanceOf(user);
        assertGt(userLpBalance, 0, "User should have received LP tokens");
    }

    /// @notice Partial withdraw from fully unstaked position — collateral should drop by ~50%
    function testWithdrawPartialFromUnstaked_collateralReduced() public {
        uint256 depositAmount = 2 ether;
        deal(WBTC_LP, portfolioAccount, depositAmount);

        _depositViaMulticall(depositAmount);

        (uint256 staked,) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        uint256 collateralFull = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();

        // Fully unstake
        _unstakeViaAuthorized(staked);

        // Withdraw half
        (, uint256 unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        uint256 halfAmount = unstaked / 2;
        _withdrawViaMulticall(halfAmount);

        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        // Strengthened assertion: collateral should be approximately 50% of the full amount
        // (within 1% tolerance to account for rounding in share-to-asset conversions)
        assertApproxEqRel(collateralAfter, collateralFull / 2, 0.01e18, "Collateral should be ~50% after half withdrawal");
        console.log("Collateral full:", collateralFull, "after half withdraw:", collateralAfter);
    }

    /// @notice Withdraw from mixed position (some staked, some unstaked)
    function testWithdrawFromMixed_collateralCleared() public {
        uint256 depositAmount = 2 ether;
        deal(WBTC_LP, portfolioAccount, depositAmount);

        _depositViaMulticall(depositAmount);

        (uint256 staked,) = YieldBasisLpFacet(portfolioAccount).getStakingState();

        // Unstake half
        uint256 halfShares = staked / 2;
        _unstakeViaAuthorized(halfShares);

        (uint256 stakedAfter, uint256 unstakedAfter) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertGt(stakedAfter, 0, "Should still have some staked");
        assertGt(unstakedAfter, 0, "Should have some unstaked");

        // Withdraw everything (unstaked + staked portions)
        uint256 totalLpAvailable = unstakedAfter + gauge.convertToAssets(stakedAfter);
        _withdrawViaMulticall(totalLpAvailable);

        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertLe(collateralAfter, 1, "Collateral must be zero (or dust) after full withdrawal");
    }

    /// @notice Withdraw from staked position (original behavior — regression check)
    function testWithdrawFromStaked_collateralCleared() public {
        uint256 depositAmount = 1 ether;
        deal(WBTC_LP, portfolioAccount, depositAmount);

        _depositViaMulticall(depositAmount);

        uint256 collateralBefore = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(collateralBefore, 0, "Should have collateral");

        // Get the actual LP amount the gauge will return for our shares
        (uint256 staked,) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        uint256 withdrawableLP = gauge.convertToAssets(staked);

        // Withdraw directly from staked (no unstake first)
        _withdrawViaMulticall(withdrawableLP);

        uint256 collateralAfter = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertLe(collateralAfter, 1, "Collateral must be zero (or dust) after full withdrawal");

        uint256 userBalance = lpToken.balanceOf(user);
        assertGt(userBalance, 0, "User should have LP tokens");
    }

    // ── Tests: Revert / Error Cases ──

    /// @notice withdraw(0) must revert with "Zero amount"
    function testRevert_withdraw_zeroAmount() public {
        uint256 depositAmount = 1 ether;
        deal(WBTC_LP, portfolioAccount, depositAmount);
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
        deal(WBTC_LP, portfolioAccount, depositAmount);
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
        deal(WBTC_LP, portfolioAccount, depositAmount);
        _depositViaMulticall(depositAmount);

        // Unstake so there is LP available for withdrawal
        (uint256 staked,) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        _unstakeViaAuthorized(staked);

        (, uint256 unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertGt(unstaked, 0, "Should have unstaked LP");

        // Direct call as user — must revert (bare require, no message)
        vm.prank(user);
        vm.expectRevert();
        YieldBasisLpFacet(portfolioAccount).withdraw(unstaked);
    }

    /// @notice Calling unstake() from a non-authorized caller must revert
    ///         due to onlyAuthorizedCaller modifier
    function testRevert_unstake_unauthorizedCaller() public {
        uint256 depositAmount = 1 ether;
        deal(WBTC_LP, portfolioAccount, depositAmount);
        _depositViaMulticall(depositAmount);

        (uint256 staked,) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertGt(staked, 0, "Should have gauge shares");

        // Random address that is NOT the authorizedCaller
        address randomCaller = address(0xdead);
        assertFalse(
            portfolioManager.isAuthorizedCaller(randomCaller),
            "randomCaller should not be authorized"
        );

        // Direct call from unauthorized address — must revert (bare require, no message)
        vm.prank(randomCaller);
        vm.expectRevert();
        YieldBasisLpFacet(portfolioAccount).unstake(staked);
    }

    /// @notice Even the portfolio owner cannot call unstake() — only authorizedCaller can
    function testRevert_unstake_ownerIsNotAuthorized() public {
        uint256 depositAmount = 1 ether;
        deal(WBTC_LP, portfolioAccount, depositAmount);
        _depositViaMulticall(depositAmount);

        (uint256 staked,) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertGt(staked, 0, "Should have gauge shares");

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
        deal(WBTC_LP, portfolioAccount, depositAmount);
        _depositViaMulticall(depositAmount);

        // Even the authorizedCaller cannot unstake 0 shares
        vm.prank(authorizedCaller);
        vm.expectRevert("Zero amount");
        YieldBasisLpFacet(portfolioAccount).unstake(0);
    }
}
