// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {YieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisLpClaimingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpClaimingFacet.sol";
import {DeployPortfolioFactoryConfig} from "../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockYieldBasisGauge} from "../../mocks/MockYieldBasisGauge.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";
import {ILendingPool} from "../../../src/interfaces/ILendingPool.sol";
import {ERC4626CollateralManager} from "../../../src/facets/account/erc4626/ERC4626CollateralManager.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract YieldBasisLpFacetTest is Test {
    YieldBasisLpFacet public _ybBtcFacet;
    YieldBasisLpClaimingFacet public _ybBtcClaimingFacet;
    PortfolioFactory public _portfolioFactory;
    PortfolioManager public _portfolioManager;
    FacetRegistry public _facetRegistry;

    PortfolioFactoryConfig public _portfolioFactoryConfig;
    LoanConfig public _loanConfig;

    MockERC20 public _ybBtc;
    MockERC20 public _ybToken; // YB reward token
    MockERC20 public _usdc;
    MockYieldBasisGauge public _gauge;
    LendingVault public _lendingVault;

    address public _user = address(0x40ac2e);
    address public _portfolioAccount;
    address public _authorizedCaller = address(0xaaaaa);
    address public _owner = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);

    uint256 constant DEPOSIT_AMOUNT = 1e18; // 1 ybBTC (18 decimals)
    uint256 constant VAULT_LIQUIDITY = 100_000e18;

    function setUp() public virtual {
        vm.startPrank(_owner);

        // Deploy portfolio manager and factory
        _portfolioManager = new PortfolioManager(_owner);
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("yb-btc-test")))
        );
        _portfolioFactory = portfolioFactory;
        _facetRegistry = facetRegistry;

        // Deploy config contracts
        DeployPortfolioFactoryConfig configDeployer = new DeployPortfolioFactoryConfig();
        (_portfolioFactoryConfig, , _loanConfig, ) = configDeployer.deploy(address(_portfolioFactory), _owner);

        // Deploy mock tokens
        _ybBtc = new MockERC20("ybBTC", "ybBTC", 18);
        _ybToken = new MockERC20("YieldBasis", "YB", 18);
        _usdc = new MockERC20("USDC", "USDC", 18);

        // Deploy mock gauge
        _gauge = new MockYieldBasisGauge(address(_ybBtc));

        // Deploy LendingVault behind ERC1967Proxy
        LendingVault lendingVaultImpl = new LendingVault();
        bytes memory initData = abi.encodeWithSelector(
            LendingVault.initialize.selector,
            address(_usdc),              // asset
            address(_portfolioFactory),  // portfolioFactory
            _owner,                      // owner
            "Lending Vault",             // name
            "lVAULT",                    // symbol
            8000,                        // maxUtilizationBps (80%)
            0                            // originationFeeBps (0 for simpler unit tests)
        );
        ERC1967Proxy lendingVaultProxy = new ERC1967Proxy(address(lendingVaultImpl), initData);
        _lendingVault = LendingVault(address(lendingVaultProxy));

        // Fund lending vault with USDC liquidity (mint directly to vault)
        _usdc.mint(address(_lendingVault), VAULT_LIQUIDITY);

        // Configure lending infrastructure
        _loanConfig.setMultiplier(7000); // 70% LTV
        _portfolioFactoryConfig.setLoanContract(address(_lendingVault));
        _portfolioFactory.setPortfolioFactoryConfig(address(_portfolioFactoryConfig));

        // Deploy and register YieldBasisLpFacet with ALL selectors including ICollateralFacet
        _ybBtcFacet = new YieldBasisLpFacet(address(_portfolioFactory), address(_gauge));
        bytes4[] memory facetSelectors = new bytes4[](9);
        facetSelectors[0] = YieldBasisLpFacet.deposit.selector;
        facetSelectors[1] = YieldBasisLpFacet.withdraw.selector;
        facetSelectors[2] = YieldBasisLpFacet.unstake.selector;
        facetSelectors[3] = YieldBasisLpFacet.restake.selector;
        facetSelectors[4] = YieldBasisLpFacet.getStakingState.selector;
        // ICollateralFacet selectors — YieldBasisLpFacet now implements ICollateralFacet
        facetSelectors[5] = ICollateralFacet.enforceCollateralRequirements.selector;
        facetSelectors[6] = ICollateralFacet.getTotalLockedCollateral.selector;
        facetSelectors[7] = ICollateralFacet.getTotalDebt.selector;
        facetSelectors[8] = ICollateralFacet.getMaxLoan.selector;
        _facetRegistry.registerFacet(address(_ybBtcFacet), facetSelectors, "YieldBasisLpFacet");

        // Deploy and register YieldBasisLpClaimingFacet
        _ybBtcClaimingFacet = new YieldBasisLpClaimingFacet(address(_portfolioFactory), address(_gauge));
        bytes4[] memory claimingSelectors = new bytes4[](2);
        claimingSelectors[0] = YieldBasisLpClaimingFacet.claimGaugeRewards.selector;
        claimingSelectors[1] = YieldBasisLpClaimingFacet.previewGaugeRewards.selector;
        _facetRegistry.registerFacet(address(_ybBtcClaimingFacet), claimingSelectors, "YieldBasisLpClaimingFacet");

        // Set authorized caller
        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);

        vm.stopPrank();

        // Create portfolio account for user
        _portfolioAccount = _portfolioFactory.createAccount(_user);

        // Mint ybBTC to user
        _ybBtc.mint(_user, DEPOSIT_AMOUNT * 10);
    }

    // ============ Helpers ============

    function _depositViaMulticall(uint256 amount) internal {
        // Transfer ybBTC to portfolio account first, then deposit via multicall
        vm.startPrank(_user);
        _ybBtc.transfer(_portfolioAccount, amount);

        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function _withdrawViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, amount);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    // ============ Deposit Tests ============

    function testDeposit() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        // ybBTC should be staked in gauge
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT);
        assertEq(unstaked, 0);
    }

    function testDepositTracksCollateral() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        // Collateral should be automatically tracked via ERC4626CollateralManager
        uint256 totalCollateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(totalCollateral, DEPOSIT_AMOUNT, "Deposit should track gauge shares as collateral");
    }

    function testDepositMultiple() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        _depositViaMulticall(DEPOSIT_AMOUNT);

        (uint256 staked, ) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT * 2);

        // Collateral should accumulate across deposits
        uint256 totalCollateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(totalCollateral, DEPOSIT_AMOUNT * 2, "Multiple deposits should accumulate collateral");
    }

    function testDepositRevertsZeroAmount() public {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, 0);
        vm.expectRevert();
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function testDepositRevertsUnauthorized() public {
        // Direct call without going through PortfolioManager
        vm.startPrank(_user);
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    // ============ Withdraw Tests ============

    function testWithdrawFromStaked() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        uint256 userBalanceBefore = _ybBtc.balanceOf(_user);
        _withdrawViaMulticall(DEPOSIT_AMOUNT);

        // User should have received ybBTC back
        uint256 userBalanceAfter = _ybBtc.balanceOf(_user);
        assertEq(userBalanceAfter - userBalanceBefore, DEPOSIT_AMOUNT);

        // Gauge should be empty
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0);
        assertEq(unstaked, 0);
    }

    function testWithdrawRemovesCollateral() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        // Verify collateral is tracked
        uint256 collateralBefore = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralBefore, DEPOSIT_AMOUNT);

        _withdrawViaMulticall(DEPOSIT_AMOUNT);

        // Collateral should be removed
        uint256 collateralAfter = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter, 0, "Withdraw should remove collateral tracking");
    }

    function testWithdrawPartialFromStaked() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        uint256 half = DEPOSIT_AMOUNT / 2;
        _withdrawViaMulticall(half);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT - half);
        assertEq(unstaked, 0);

        assertEq(_ybBtc.balanceOf(_user), DEPOSIT_AMOUNT * 10 - DEPOSIT_AMOUNT + half);

        // Partial collateral should remain
        uint256 collateralAfter = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter, DEPOSIT_AMOUNT - half, "Partial withdraw should leave remaining collateral");
    }

    function testWithdrawFromUnstaked() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        // Admin unstakes first
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        // Now withdraw — should pull from unstaked balance directly (no gauge interaction needed)
        uint256 userBalanceBefore = _ybBtc.balanceOf(_user);
        _withdrawViaMulticall(DEPOSIT_AMOUNT);
        uint256 userBalanceAfter = _ybBtc.balanceOf(_user);

        assertEq(userBalanceAfter - userBalanceBefore, DEPOSIT_AMOUNT);
    }

    function testWithdrawFromMixedStakedUnstaked() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        // Admin unstakes half
        uint256 half = DEPOSIT_AMOUNT / 2;
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(half);

        // Withdraw full amount — should use unstaked first, then unstake the rest
        uint256 userBalanceBefore = _ybBtc.balanceOf(_user);
        _withdrawViaMulticall(DEPOSIT_AMOUNT);
        uint256 userBalanceAfter = _ybBtc.balanceOf(_user);

        assertEq(userBalanceAfter - userBalanceBefore, DEPOSIT_AMOUNT);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0);
        assertEq(unstaked, 0);
    }

    function testWithdrawRevertsZeroAmount() public {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, 0);
        vm.expectRevert();
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function testWithdrawRevertsUnauthorized() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        vm.startPrank(address(0xdead));
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).withdraw(DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    // ============ Unstake Tests (Admin Only) ============

    function testUnstake() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0);
        assertEq(unstaked, DEPOSIT_AMOUNT);
    }

    function testUnstakePartial() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        uint256 half = DEPOSIT_AMOUNT / 2;
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(half);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT - half);
        assertEq(unstaked, half);
    }

    function testUnstakeRevertsUnauthorized() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        vm.startPrank(_user);
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function testUnstakeRevertsZeroAmount() public {
        vm.prank(_authorizedCaller);
        vm.expectRevert("Zero amount");
        YieldBasisLpFacet(_portfolioAccount).unstake(0);
    }

    // ============ Restake Tests (Admin Only) ============

    function testRestake() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        // Unstake first
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        // Restake
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).restake(DEPOSIT_AMOUNT);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT);
        assertEq(unstaked, 0);
    }

    function testRestakePartial() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        uint256 half = DEPOSIT_AMOUNT / 2;
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).restake(half);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, half);
        assertEq(unstaked, DEPOSIT_AMOUNT - half);
    }

    function testRestakeRevertsUnauthorized() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        vm.startPrank(_user);
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).restake(DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function testRestakeRevertsZeroAmount() public {
        vm.prank(_authorizedCaller);
        vm.expectRevert("Zero amount");
        YieldBasisLpFacet(_portfolioAccount).restake(0);
    }

    // ============ Claiming Tests ============

    function testClaimGaugeRewards() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        // Setup claimable rewards
        uint256 rewardAmount = 100e18;
        _ybToken.mint(address(_gauge), rewardAmount);
        _gauge.setClaimableRewards(_portfolioAccount, address(_ybToken), rewardAmount);

        // Claim as authorized caller
        vm.prank(_authorizedCaller);
        uint256 claimed = YieldBasisLpClaimingFacet(_portfolioAccount).claimGaugeRewards(address(_ybToken));

        assertEq(claimed, rewardAmount);
        assertEq(_ybToken.balanceOf(_portfolioAccount), rewardAmount);
    }

    function testPreviewGaugeRewards() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        uint256 rewardAmount = 50e18;
        _gauge.setClaimableRewards(_portfolioAccount, address(_ybToken), rewardAmount);

        uint256 preview = YieldBasisLpClaimingFacet(_portfolioAccount).previewGaugeRewards(address(_ybToken));
        assertEq(preview, rewardAmount);
    }

    function testClaimGaugeRewardsRevertsUnauthorized() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        vm.startPrank(_user);
        vm.expectRevert();
        YieldBasisLpClaimingFacet(_portfolioAccount).claimGaugeRewards(address(_ybToken));
        vm.stopPrank();
    }

    // ============ ICollateralFacet View Functions ============

    function testGetTotalLockedCollateralZeroBeforeDeposit() public view {
        uint256 collateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral, 0, "No collateral before deposit");
    }

    function testGetTotalLockedCollateralAfterDeposit() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        uint256 collateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral, DEPOSIT_AMOUNT, "Collateral should equal deposited gauge shares");
    }

    function testGetTotalDebtZero() public view {
        uint256 debt = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, 0, "No debt initially");
    }

    function testGetMaxLoanZeroWithoutCollateral() public view {
        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = ICollateralFacet(_portfolioAccount).getMaxLoan();
        assertEq(maxLoan, 0, "Max loan should be 0 without collateral");
        assertEq(maxLoanIgnoreSupply, 0, "Max loan ignore supply should be 0 without collateral");
    }

    function testGetMaxLoanAfterDeposit() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = ICollateralFacet(_portfolioAccount).getMaxLoan();
        // 70% LTV of 1e18 = 7e17
        uint256 expectedMaxLoanIgnoreSupply = (DEPOSIT_AMOUNT * 7000) / 10000;
        assertEq(maxLoanIgnoreSupply, expectedMaxLoanIgnoreSupply, "Max loan should reflect 70% LTV");
        assertGt(maxLoan, 0, "Max loan should be > 0 with collateral and vault liquidity");
    }

    function testEnforceCollateralRequirementsPassesWithNoDebt() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        bool success = ICollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Should pass with collateral and no debt");
    }

    function testEnforceCollateralRequirementsPassesEmpty() public view {
        // No collateral, no debt — should pass
        bool success = ICollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success, "Should pass with no collateral and no debt");
    }

    // ============ Full Flow Tests ============

    function testFullFlow_DepositUnstakeRestakeWithdraw() public {
        // 1. Deposit — staked in gauge
        _depositViaMulticall(DEPOSIT_AMOUNT);
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT);
        assertEq(unstaked, 0);

        // 2. Admin unstakes — switch to trading fees mode
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);
        (staked, unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0);
        assertEq(unstaked, DEPOSIT_AMOUNT);

        // 3. Admin restakes — switch back to YB emissions mode
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).restake(DEPOSIT_AMOUNT);
        (staked, unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT);
        assertEq(unstaked, 0);

        // 4. User withdraws — unstakes from gauge and sends ybBTC to user
        uint256 userBalanceBefore = _ybBtc.balanceOf(_user);
        _withdrawViaMulticall(DEPOSIT_AMOUNT);
        assertEq(_ybBtc.balanceOf(_user) - userBalanceBefore, DEPOSIT_AMOUNT);
    }

    function testFullFlow_DepositClaimWithdraw() public {
        // 1. Deposit
        _depositViaMulticall(DEPOSIT_AMOUNT);

        // 2. Accumulate and claim rewards
        uint256 rewardAmount = 100e18;
        _ybToken.mint(address(_gauge), rewardAmount);
        _gauge.setClaimableRewards(_portfolioAccount, address(_ybToken), rewardAmount);

        vm.prank(_authorizedCaller);
        YieldBasisLpClaimingFacet(_portfolioAccount).claimGaugeRewards(address(_ybToken));
        assertEq(_ybToken.balanceOf(_portfolioAccount), rewardAmount);

        // 3. Withdraw ybBTC
        uint256 userBalanceBefore = _ybBtc.balanceOf(_user);
        _withdrawViaMulticall(DEPOSIT_AMOUNT);
        assertEq(_ybBtc.balanceOf(_user) - userBalanceBefore, DEPOSIT_AMOUNT);

        // Collateral should be fully removed after withdraw
        uint256 collateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral, 0, "Collateral should be 0 after full withdraw");
    }

    // ============ Event Emission Tests ============

    function testDepositEmitsEvent() public {
        vm.startPrank(_user);
        _ybBtc.transfer(_portfolioAccount, DEPOSIT_AMOUNT);

        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, DEPOSIT_AMOUNT);

        // The Deposited event is emitted by the facet with msg.sender = portfolioManager
        vm.expectEmit(true, false, false, true, _portfolioAccount);
        emit YieldBasisLpFacet.Deposited(address(_portfolioManager), DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function testWithdrawEmitsEvent() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, DEPOSIT_AMOUNT);

        vm.expectEmit(true, false, false, true, _portfolioAccount);
        emit YieldBasisLpFacet.Withdrawn(_user, DEPOSIT_AMOUNT);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function testUnstakeEmitsEvent() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        vm.expectEmit(false, false, false, true, _portfolioAccount);
        emit YieldBasisLpFacet.Unstaked(DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);
    }

    function testRestakeEmitsEvent() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        vm.expectEmit(false, false, false, true, _portfolioAccount);
        emit YieldBasisLpFacet.Restaked(DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).restake(DEPOSIT_AMOUNT);
    }

    function testClaimGaugeRewardsEmitsEvent() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        uint256 rewardAmount = 100e18;
        _ybToken.mint(address(_gauge), rewardAmount);
        _gauge.setClaimableRewards(_portfolioAccount, address(_ybToken), rewardAmount);

        vm.expectEmit(true, false, false, true, _portfolioAccount);
        emit YieldBasisLpClaimingFacet.GaugeRewardsClaimed(address(_ybToken), rewardAmount);
        vm.prank(_authorizedCaller);
        YieldBasisLpClaimingFacet(_portfolioAccount).claimGaugeRewards(address(_ybToken));
    }

    // ============ Boundary / Edge Case Tests ============

    function testWithdrawRevertsInsufficientBalance() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        // Try to withdraw more than deposited
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, DEPOSIT_AMOUNT + 1);
        vm.expectRevert();
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function testUnstakeRevertsInsufficientStaked() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        // Try to unstake more than staked
        vm.prank(_authorizedCaller);
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT + 1);
    }

    function testRestakeRevertsInsufficientUnstaked() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        // Try to restake more than unstaked
        vm.prank(_authorizedCaller);
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).restake(DEPOSIT_AMOUNT + 1);
    }

    function testClaimZeroRewards() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        // Claim with no rewards set — should return 0 and not revert
        vm.prank(_authorizedCaller);
        uint256 claimed = YieldBasisLpClaimingFacet(_portfolioAccount).claimGaugeRewards(address(_ybToken));
        assertEq(claimed, 0);
        assertEq(_ybToken.balanceOf(_portfolioAccount), 0);
    }

    function testPreviewGaugeRewardsZero() public view {
        // Preview when no rewards set
        uint256 preview = YieldBasisLpClaimingFacet(_portfolioAccount).previewGaugeRewards(address(_ybToken));
        assertEq(preview, 0);
    }

    function testPreviewAfterClaim() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        uint256 rewardAmount = 50e18;
        _ybToken.mint(address(_gauge), rewardAmount);
        _gauge.setClaimableRewards(_portfolioAccount, address(_ybToken), rewardAmount);

        // Preview shows rewards
        uint256 preview = YieldBasisLpClaimingFacet(_portfolioAccount).previewGaugeRewards(address(_ybToken));
        assertEq(preview, rewardAmount);

        // Claim them
        vm.prank(_authorizedCaller);
        YieldBasisLpClaimingFacet(_portfolioAccount).claimGaugeRewards(address(_ybToken));

        // Preview should now be 0
        preview = YieldBasisLpClaimingFacet(_portfolioAccount).previewGaugeRewards(address(_ybToken));
        assertEq(preview, 0);
    }

    function testDepositApprovalsCleared() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        // After deposit, approval from portfolio account to gauge should be 0
        uint256 allowance = _ybBtc.allowance(_portfolioAccount, address(_gauge));
        assertEq(allowance, 0, "Gauge allowance should be reset to 0 after deposit");
    }

    function testRestakeApprovalsCleared() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).restake(DEPOSIT_AMOUNT);

        // After restake, approval from portfolio account to gauge should be 0
        uint256 allowance = _ybBtc.allowance(_portfolioAccount, address(_gauge));
        assertEq(allowance, 0, "Gauge allowance should be reset to 0 after restake");
    }

    // ============ Access Control: Owner vs AuthorizedCaller ============

    function testUnstakeRevertsForOwner() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        // _owner is the PortfolioManager owner but NOT an authorized caller
        vm.prank(_owner);
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);
    }

    function testRestakeRevertsForOwner() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        vm.prank(_owner);
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).restake(DEPOSIT_AMOUNT);
    }

    function testClaimRevertsForOwner() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        vm.prank(_owner);
        vm.expectRevert();
        YieldBasisLpClaimingFacet(_portfolioAccount).claimGaugeRewards(address(_ybToken));
    }

    function testDepositRevertsRandomCaller() public {
        // Random address calling deposit directly (not via multicall)
        vm.prank(address(0xbad));
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).deposit(DEPOSIT_AMOUNT);
    }

    function testClaimRevertsRandomCaller() public {
        vm.prank(address(0xbad));
        vm.expectRevert();
        YieldBasisLpClaimingFacet(_portfolioAccount).claimGaugeRewards(address(_ybToken));
    }

    function testUnstakeRevertsRandomCaller() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        vm.prank(address(0xbad));
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);
    }

    function testRestakeRevertsRandomCaller() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        vm.prank(address(0xbad));
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).restake(DEPOSIT_AMOUNT);
    }

    // ============ getStakingState Tests ============

    function testGetStakingStateEmpty() public view {
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0);
        assertEq(unstaked, 0);
    }

    function testGetStakingStateAfterDeposit() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT);
        assertEq(unstaked, 0);
    }

    function testGetStakingStateMixed() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        uint256 half = DEPOSIT_AMOUNT / 2;
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(half);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT - half);
        assertEq(unstaked, half);
    }

    // ============ HARDENED TESTS: Deposit Edge Cases ============

    /// @notice Deposit should revert if ybBTC was NOT transferred to the portfolio account first
    function testDepositRevertsWithoutPriorTransfer() public {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, DEPOSIT_AMOUNT);
        // No transfer to _portfolioAccount, so the approve+deposit in gauge should fail
        vm.expectRevert();
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /// @notice Deposit more than the ybBTC balance on the portfolio account should revert
    function testDepositRevertsAmountExceedsBalance() public {
        uint256 small = DEPOSIT_AMOUNT / 10;
        vm.startPrank(_user);
        _ybBtc.transfer(_portfolioAccount, small);

        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        // Try to deposit more than was transferred
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, small + 1);
        vm.expectRevert();
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /// @notice Deposit when there's already unstaked ybBTC sitting on the contract
    ///         (e.g., after an admin unstake). The deposit REVERTS because
    ///         ERC4626CollateralManager.addCollateral checks that gauge share balance
    ///         covers data.shares + newShares. Since unstaking removes gauge shares
    ///         but doesn't reduce data.shares, the check fails.
    ///         This is correct behavior: admin must restake before new deposits are possible.
    function testDepositWorksAfterUnstake() public {
        // First deposit and unstake — collateral tracking is properly cleared
        _depositViaMulticall(DEPOSIT_AMOUNT);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        // Second deposit should succeed since unstake properly cleared data.shares
        uint256 secondDeposit = DEPOSIT_AMOUNT / 2;
        vm.startPrank(_user);
        _ybBtc.transfer(_portfolioAccount, secondDeposit);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, secondDeposit);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        (uint256 staked, ) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, secondDeposit);
        uint256 collateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral, secondDeposit);
    }

    // ============ HARDENED TESTS: Withdraw Edge Cases ============

    /// @notice Withdraw with no prior deposit should revert
    function testWithdrawRevertsWithNoDeposit() public {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, DEPOSIT_AMOUNT);
        vm.expectRevert();
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /// @notice Withdraw 1 wei more than deposited should revert
    function testWithdrawRevertsOneWeiOver() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, DEPOSIT_AMOUNT + 1);
        vm.expectRevert();
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /// @notice After full withdrawal, a second withdrawal of any amount should revert
    function testDoubleWithdrawReverts() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        _withdrawViaMulticall(DEPOSIT_AMOUNT);

        // Second withdrawal should fail -- nothing left
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, 1);
        vm.expectRevert();
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /// @notice Multiple deposit/withdraw cycles should maintain correct accounting
    function testMultipleDepositWithdrawCycles() public {
        uint256 userBalanceBefore = _ybBtc.balanceOf(_user);

        // Cycle 1
        _depositViaMulticall(DEPOSIT_AMOUNT);
        _withdrawViaMulticall(DEPOSIT_AMOUNT);

        // Cycle 2
        _depositViaMulticall(DEPOSIT_AMOUNT / 2);
        _withdrawViaMulticall(DEPOSIT_AMOUNT / 2);

        // Cycle 3
        _depositViaMulticall(DEPOSIT_AMOUNT);
        _depositViaMulticall(DEPOSIT_AMOUNT);
        _withdrawViaMulticall(DEPOSIT_AMOUNT * 2);

        uint256 userBalanceAfter = _ybBtc.balanceOf(_user);
        assertEq(userBalanceAfter, userBalanceBefore, "User should have exact same balance after full cycles");

        // All state should be clean
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0, "No staked after full withdrawal");
        assertEq(unstaked, 0, "No unstaked after full withdrawal");
        uint256 collateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral, 0, "Collateral should be 0 after all withdrawals");
    }

    /// @notice Partial withdrawals in small steps should sum correctly
    function testIncrementalWithdrawals() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        uint256 step = DEPOSIT_AMOUNT / 10;
        uint256 userBefore = _ybBtc.balanceOf(_user);

        for (uint256 i = 0; i < 10; i++) {
            _withdrawViaMulticall(step);
        }

        uint256 userAfter = _ybBtc.balanceOf(_user);
        assertEq(userAfter - userBefore, DEPOSIT_AMOUNT, "10 partial withdrawals should return full amount");

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0);
        assertEq(unstaked, 0);
    }

    // ============ HARDENED TESTS: Unstake/Restake Edge Cases ============

    /// @notice Unstake with zero gauge balance (nothing deposited) should revert
    function testUnstakeRevertsWithNoDeposit() public {
        vm.prank(_authorizedCaller);
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);
    }

    /// @notice Restake with zero unstaked ybBTC should revert
    function testRestakeRevertsWithNoUnstakedBalance() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        // Everything is staked, nothing to restake
        vm.prank(_authorizedCaller);
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).restake(DEPOSIT_AMOUNT);
    }

    /// @notice Multiple unstake/restake cycles should maintain correct balances
    function testMultipleUnstakeRestakeCycles() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(_authorizedCaller);
            YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);
            (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
            assertEq(staked, 0, "Should be fully unstaked");
            assertEq(unstaked, DEPOSIT_AMOUNT, "Should have full unstaked balance");

            vm.prank(_authorizedCaller);
            YieldBasisLpFacet(_portfolioAccount).restake(DEPOSIT_AMOUNT);
            (staked, unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
            assertEq(staked, DEPOSIT_AMOUNT, "Should be fully staked");
            assertEq(unstaked, 0, "Should have no unstaked balance");
        }

        // Collateral tracking should still be correct
        uint256 collateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral, DEPOSIT_AMOUNT, "Collateral should be unchanged after cycles");
    }

    /// @notice Unstake partial, restake partial, then withdraw everything
    function testPartialUnstakeRestakeThenFullWithdraw() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        uint256 quarter = DEPOSIT_AMOUNT / 4;

        // Unstake half
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(quarter * 2);

        // Restake a quarter
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).restake(quarter);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT - quarter, "3/4 should be staked");
        assertEq(unstaked, quarter, "1/4 should be unstaked");

        // Withdraw everything -- should pull from unstaked + gauge
        uint256 userBefore = _ybBtc.balanceOf(_user);
        _withdrawViaMulticall(DEPOSIT_AMOUNT);
        assertEq(_ybBtc.balanceOf(_user) - userBefore, DEPOSIT_AMOUNT);
    }

    // ============ HARDENED TESTS: Collateral Invariants ============

    /// @notice Collateral should always equal gauge shares tracked, not ybBTC balance
    function testCollateralClearedAfterUnstake() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        // Unstake removes gauge shares and updates collateral tracking
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        // Gauge balance is 0, ybBTC balance is DEPOSIT_AMOUNT
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0);
        assertEq(unstaked, DEPOSIT_AMOUNT);

        // Collateral should be 0 since gauge shares were burned and removed from tracking
        uint256 collateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral, 0, "Collateral should be zero after unstake");
    }

    /// @notice enforceCollateralRequirements after deposit with no debt should always pass
    function testEnforceCollateralRequirementsAfterMultipleDeposits() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        _depositViaMulticall(DEPOSIT_AMOUNT);

        bool success = ICollateralFacet(_portfolioAccount).enforceCollateralRequirements();
        assertTrue(success);

        uint256 collateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral, DEPOSIT_AMOUNT * 2);
    }

    // ============ HARDENED TESTS: Fuzz Testing ============

    /// @notice Fuzz deposit amount: any non-zero amount up to user's balance should work
    function testFuzzDeposit(uint256 amount) public {
        uint256 maxBalance = _ybBtc.balanceOf(_user);
        amount = bound(amount, 1, maxBalance);

        _depositViaMulticall(amount);

        (uint256 staked, ) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, amount);
        uint256 collateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral, amount);
    }

    /// @notice Fuzz deposit then withdraw: any amount deposited can be fully withdrawn
    function testFuzzDepositAndWithdraw(uint256 amount) public {
        uint256 maxBalance = _ybBtc.balanceOf(_user);
        amount = bound(amount, 1, maxBalance);

        uint256 userBefore = _ybBtc.balanceOf(_user);
        _depositViaMulticall(amount);
        _withdrawViaMulticall(amount);
        uint256 userAfter = _ybBtc.balanceOf(_user);

        assertEq(userAfter, userBefore, "User should get exact amount back");

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0);
        assertEq(unstaked, 0);
    }

    /// @notice Fuzz partial withdraw: withdraw <= deposit should succeed
    function testFuzzPartialWithdraw(uint256 depositAmt, uint256 withdrawAmt) public {
        uint256 maxBalance = _ybBtc.balanceOf(_user);
        depositAmt = bound(depositAmt, 1, maxBalance);
        withdrawAmt = bound(withdrawAmt, 1, depositAmt);

        _depositViaMulticall(depositAmt);

        uint256 userBefore = _ybBtc.balanceOf(_user);
        _withdrawViaMulticall(withdrawAmt);
        uint256 userAfter = _ybBtc.balanceOf(_user);

        assertEq(userAfter - userBefore, withdrawAmt, "Should receive exact withdrawal amount");

        uint256 remaining = depositAmt - withdrawAmt;
        (uint256 staked, ) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, remaining, "Remaining stake should be deposit - withdrawal");
    }

    /// @notice Fuzz unstake: unstake amount <= staked should succeed
    function testFuzzUnstake(uint256 unstakeAmt) public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        unstakeAmt = bound(unstakeAmt, 1, DEPOSIT_AMOUNT);

        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(unstakeAmt);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT - unstakeAmt);
        assertEq(unstaked, unstakeAmt);
    }

    // ============ HARDENED TESTS: Claiming Edge Cases ============

    /// @notice Claiming rewards with a non-existent reward token address should return 0
    function testClaimNonExistentRewardToken() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        address fakeToken = address(0x1234);
        vm.prank(_authorizedCaller);
        uint256 claimed = YieldBasisLpClaimingFacet(_portfolioAccount).claimGaugeRewards(fakeToken);
        assertEq(claimed, 0);
    }

    /// @notice Double-claiming should yield 0 on the second call
    function testDoubleClaimYieldsZeroSecondTime() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        uint256 rewardAmount = 100e18;
        _ybToken.mint(address(_gauge), rewardAmount);
        _gauge.setClaimableRewards(_portfolioAccount, address(_ybToken), rewardAmount);

        // First claim
        vm.prank(_authorizedCaller);
        uint256 claimed1 = YieldBasisLpClaimingFacet(_portfolioAccount).claimGaugeRewards(address(_ybToken));
        assertEq(claimed1, rewardAmount);

        // Second claim -- should be 0
        vm.prank(_authorizedCaller);
        uint256 claimed2 = YieldBasisLpClaimingFacet(_portfolioAccount).claimGaugeRewards(address(_ybToken));
        assertEq(claimed2, 0, "Second claim should yield nothing");
    }

    /// @notice Claiming with no deposit should return 0 (no revert)
    function testClaimWithNoDeposit() public {
        vm.prank(_authorizedCaller);
        uint256 claimed = YieldBasisLpClaimingFacet(_portfolioAccount).claimGaugeRewards(address(_ybToken));
        assertEq(claimed, 0);
    }

    // ============ HARDENED TESTS: Withdraw Sends to Correct Recipient ============

    /// @notice Withdraw should send ybBTC to the portfolio owner, not msg.sender or the contract
    function testWithdrawSendsToOwnerNotCaller() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        uint256 ownerBefore = _ybBtc.balanceOf(_user);
        uint256 accountBefore = _ybBtc.balanceOf(_portfolioAccount);

        _withdrawViaMulticall(DEPOSIT_AMOUNT);

        uint256 ownerAfter = _ybBtc.balanceOf(_user);
        uint256 accountAfter = _ybBtc.balanceOf(_portfolioAccount);

        assertEq(ownerAfter - ownerBefore, DEPOSIT_AMOUNT, "Owner should receive ybBTC");
        assertEq(accountAfter, 0, "Portfolio account should have 0 ybBTC");
        // Note: accountBefore should also be 0 since deposit stakes everything
        assertEq(accountBefore, 0, "Account should have had 0 ybBTC while staked");
    }

    // ============ HARDENED TESTS: Constructor Validation ============

    /// @notice Constructor should revert with zero address for portfolioFactory
    function testConstructorRevertsZeroFactory() public {
        vm.expectRevert("Invalid portfolio factory");
        new YieldBasisLpFacet(address(0), address(_gauge));
    }

    /// @notice Constructor should revert with zero address for gauge
    function testConstructorRevertsZeroGauge() public {
        vm.expectRevert("Invalid gauge");
        new YieldBasisLpFacet(address(_portfolioFactory), address(0));
    }

    /// @notice ClaimingFacet constructor should revert with zero address
    function testClaimingConstructorRevertsZeroFactory() public {
        vm.expectRevert("Invalid portfolio factory");
        new YieldBasisLpClaimingFacet(address(0), address(_gauge));
    }

    function testClaimingConstructorRevertsZeroGauge() public {
        vm.expectRevert("Invalid gauge");
        new YieldBasisLpClaimingFacet(address(_portfolioFactory), address(0));
    }

    // ============ HARDENED TESTS: Minimum Amount (1 wei) ============

    /// @notice Deposit and withdraw 1 wei should work correctly
    function testDepositAndWithdrawOneWei() public {
        _depositViaMulticall(1);

        (uint256 staked, ) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 1);

        uint256 collateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral, 1);

        uint256 userBefore = _ybBtc.balanceOf(_user);
        _withdrawViaMulticall(1);
        assertEq(_ybBtc.balanceOf(_user) - userBefore, 1);
    }

    // ============ HARDENED TESTS: Large Amount ============

    /// @notice Deposit and withdraw large amount near uint256 range
    function testDepositAndWithdrawLargeAmount() public {
        uint256 largeAmount = 1_000_000e18;
        _ybBtc.mint(_user, largeAmount);

        _depositViaMulticall(largeAmount);

        (uint256 staked, ) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, largeAmount);

        uint256 userBefore = _ybBtc.balanceOf(_user);
        _withdrawViaMulticall(largeAmount);
        assertEq(_ybBtc.balanceOf(_user) - userBefore, largeAmount);
    }

    // ============ HARDENED TESTS: State After Failed Operations ============

    /// @notice State should be unchanged after a failed withdraw (revert)
    function testStateUnchangedAfterFailedWithdraw() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        (uint256 stakedBefore, uint256 unstakedBefore) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        uint256 collateralBefore = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        uint256 userBalBefore = _ybBtc.balanceOf(_user);

        // Attempt overwithdraw -- should revert
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, DEPOSIT_AMOUNT + 1);
        vm.expectRevert();
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        // All state should be identical
        (uint256 stakedAfter, uint256 unstakedAfter) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(stakedAfter, stakedBefore, "Staked unchanged after failed withdraw");
        assertEq(unstakedAfter, unstakedBefore, "Unstaked unchanged after failed withdraw");
        assertEq(ICollateralFacet(_portfolioAccount).getTotalLockedCollateral(), collateralBefore, "Collateral unchanged");
        assertEq(_ybBtc.balanceOf(_user), userBalBefore, "User balance unchanged");
    }

    // ============ HARDENED TESTS: ICollateralFacet After Complex Flows ============

    /// @notice getMaxLoan should decrease after partial withdrawal
    function testMaxLoanDecreasesAfterPartialWithdraw() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        (, uint256 maxLoanFullIS) = ICollateralFacet(_portfolioAccount).getMaxLoan();

        uint256 half = DEPOSIT_AMOUNT / 2;
        _withdrawViaMulticall(half);

        (, uint256 maxLoanHalfIS) = ICollateralFacet(_portfolioAccount).getMaxLoan();
        assertLt(maxLoanHalfIS, maxLoanFullIS, "Max loan should decrease after partial withdrawal");
        // Should be approximately half (within rounding)
        assertEq(maxLoanHalfIS, (half * 7000) / 10000, "Max loan should reflect half collateral at 70% LTV");
    }

    /// @notice getTotalDebt should be 0 when no borrowing has occurred, regardless of deposits
    function testTotalDebtZeroWithDepositsOnly() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);
        _depositViaMulticall(DEPOSIT_AMOUNT);

        uint256 debt = ICollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debt, 0, "Debt should be 0 with deposits only");
    }
}
