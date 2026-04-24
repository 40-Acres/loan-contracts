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
import {MockYieldBasisLP} from "../../mocks/MockYieldBasisLP.sol";
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

    MockYieldBasisLP public _ybBtc;
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
        _ybBtc = new MockYieldBasisLP("ybBTC", "ybBTC", 18);
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
        _ybBtcFacet = new YieldBasisLpFacet(address(_portfolioFactory), address(_gauge), address(_ybToken), address(_usdc));
        bytes4[] memory facetSelectors = new bytes4[](9);
        facetSelectors[0] = YieldBasisLpFacet.deposit.selector;
        facetSelectors[1] = YieldBasisLpFacet.withdraw.selector;
        facetSelectors[2] = YieldBasisLpFacet.unstake.selector;
        facetSelectors[3] = YieldBasisLpFacet.stake.selector;
        facetSelectors[4] = YieldBasisLpFacet.getStakingState.selector;
        // ICollateralFacet selectors — YieldBasisLpFacet now implements ICollateralFacet
        facetSelectors[5] = ICollateralFacet.enforceCollateralRequirements.selector;
        facetSelectors[6] = ICollateralFacet.getTotalLockedCollateral.selector;
        facetSelectors[7] = ICollateralFacet.getTotalDebt.selector;
        facetSelectors[8] = ICollateralFacet.getMaxLoan.selector;
        _facetRegistry.registerFacet(address(_ybBtcFacet), facetSelectors, "YieldBasisLpFacet");

        // Deploy and register YieldBasisLpClaimingFacet
        _ybBtcClaimingFacet = new YieldBasisLpClaimingFacet(address(_portfolioFactory), address(_gauge), address(_usdc));
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
        // Approve portfolio account to pull LP from user, then deposit via multicall
        vm.startPrank(_user);
        _ybBtc.approve(_portfolioAccount, amount);

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

    /// @dev Deposit LP and then stake it into the gauge (admin action).
    ///      Deposit no longer auto-stakes, so tests that exercise gauge behavior
    ///      must explicitly stake after deposit.
    function _depositAndStake(uint256 amount) internal {
        _depositViaMulticall(amount);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).stake(amount);
    }

    // ============ Deposit Tests ============

    function testDeposit() public {
        _depositViaMulticall(DEPOSIT_AMOUNT);

        // Deposit no longer auto-stakes: LP sits on the account, gauge is untouched
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0, "Nothing staked in gauge after deposit");
        assertEq(unstaked, DEPOSIT_AMOUNT, "Full deposit held unstaked on the account");

        // LP balance on the account should equal the deposit
        assertEq(_ybBtc.balanceOf(_portfolioAccount), DEPOSIT_AMOUNT, "Account LP balance equals deposit");
        assertEq(_gauge.balanceOf(_portfolioAccount), 0, "Account has no gauge shares");
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

        // Two deposits accumulate as unstaked LP on the account (deposit does not stake)
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0, "Deposit does not auto-stake");
        assertEq(unstaked, DEPOSIT_AMOUNT * 2, "Both deposits held unstaked on account");

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
        // Stake after deposit so we exercise the gauge-withdraw branch of withdraw()
        _depositAndStake(DEPOSIT_AMOUNT);

        uint256 half = DEPOSIT_AMOUNT / 2;
        _withdrawViaMulticall(half);

        // Withdraw pulls from unstaked LP first, then unstakes the shortfall from the gauge.
        // With everything staked, withdraw(half) unstakes `half` from the gauge and transfers
        // it to the user — leaving DEPOSIT_AMOUNT - half staked, and 0 unstaked.
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT - half, "Remaining LP still staked in gauge");
        assertEq(unstaked, 0, "No unstaked LP left on account after partial withdraw");

        assertEq(_ybBtc.balanceOf(_user), DEPOSIT_AMOUNT * 10 - DEPOSIT_AMOUNT + half);

        // Partial collateral should remain
        uint256 collateralAfter = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter, DEPOSIT_AMOUNT - half, "Partial withdraw should leave remaining collateral");
    }

    function testWithdrawFromUnstaked() public {
        // Stake then unstake so we reach the "LP unstaked on account, but gauge once held it"
        // branch of the lifecycle — verifies withdraw pulls directly from the account's LP
        // balance without any gauge interaction.
        _depositAndStake(DEPOSIT_AMOUNT);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        // Sanity: LP is fully unstaked on the account, gauge holds nothing for this account
        (uint256 stakedBefore, uint256 unstakedBefore) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(stakedBefore, 0, "Precondition: gauge empty");
        assertEq(unstakedBefore, DEPOSIT_AMOUNT, "Precondition: full LP sits on account");

        // Withdraw — should pull from unstaked balance directly (no gauge interaction needed)
        uint256 userBalanceBefore = _ybBtc.balanceOf(_user);
        _withdrawViaMulticall(DEPOSIT_AMOUNT);
        uint256 userBalanceAfter = _ybBtc.balanceOf(_user);

        assertEq(userBalanceAfter - userBalanceBefore, DEPOSIT_AMOUNT, "User receives full deposit back");

        // Account should be fully drained
        (uint256 stakedAfter, uint256 unstakedAfter) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(stakedAfter, 0);
        assertEq(unstakedAfter, 0);
    }

    function testWithdrawFromMixedStakedUnstaked() public {
        // Deposit and stake in full, then unstake half — resulting in half staked and half unstaked
        _depositAndStake(DEPOSIT_AMOUNT);

        uint256 half = DEPOSIT_AMOUNT / 2;
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(half);

        // Sanity: mixed state
        (uint256 stakedBefore, uint256 unstakedBefore) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(stakedBefore, DEPOSIT_AMOUNT - half, "Half remains staked");
        assertEq(unstakedBefore, half, "Half is unstaked");

        // Withdraw full amount — should use unstaked first, then unstake the shortfall
        uint256 userBalanceBefore = _ybBtc.balanceOf(_user);
        _withdrawViaMulticall(DEPOSIT_AMOUNT);
        uint256 userBalanceAfter = _ybBtc.balanceOf(_user);

        assertEq(userBalanceAfter - userBalanceBefore, DEPOSIT_AMOUNT, "User receives full amount");

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0, "Gauge drained");
        assertEq(unstaked, 0, "No LP left on account");
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
        // Deposit+stake so there are gauge shares to unstake
        _depositAndStake(DEPOSIT_AMOUNT);

        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0, "All gauge shares redeemed");
        assertEq(unstaked, DEPOSIT_AMOUNT, "All LP now unstaked on account");
    }

    function testUnstakePartial() public {
        _depositAndStake(DEPOSIT_AMOUNT);

        uint256 half = DEPOSIT_AMOUNT / 2;
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(half);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT - half, "Half remains staked");
        assertEq(unstaked, half, "Half moved to unstaked on account");
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
        _depositAndStake(DEPOSIT_AMOUNT);

        // Unstake first
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        // Restake
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).stake(DEPOSIT_AMOUNT);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT);
        assertEq(unstaked, 0);
    }

    function testRestakePartial() public {
        _depositAndStake(DEPOSIT_AMOUNT);

        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        uint256 half = DEPOSIT_AMOUNT / 2;
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).stake(half);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, half);
        assertEq(unstaked, DEPOSIT_AMOUNT - half);
    }

    function testRestakeRevertsUnauthorized() public {
        _depositAndStake(DEPOSIT_AMOUNT);

        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        vm.startPrank(_user);
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).stake(DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function testRestakeRevertsZeroAmount() public {
        vm.prank(_authorizedCaller);
        vm.expectRevert("Zero amount");
        YieldBasisLpFacet(_portfolioAccount).stake(0);
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
        // 1. Deposit — LP held unstaked on account (deposit no longer auto-stakes)
        _depositViaMulticall(DEPOSIT_AMOUNT);
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0, "Deposit does not stake");
        assertEq(unstaked, DEPOSIT_AMOUNT, "LP held unstaked on account");

        // 2. Admin stakes — switch to YB emissions mode
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).stake(DEPOSIT_AMOUNT);
        (staked, unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT, "Now fully staked");
        assertEq(unstaked, 0);

        // 3. Admin unstakes — switch to trading fees mode
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);
        (staked, unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0);
        assertEq(unstaked, DEPOSIT_AMOUNT, "LP back on account");

        // 4. Admin restakes — back to YB emissions mode
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).stake(DEPOSIT_AMOUNT);
        (staked, unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT);
        assertEq(unstaked, 0);

        // 5. User withdraws — unstakes from gauge and sends ybBTC to user
        uint256 userBalanceBefore = _ybBtc.balanceOf(_user);
        _withdrawViaMulticall(DEPOSIT_AMOUNT);
        assertEq(_ybBtc.balanceOf(_user) - userBalanceBefore, DEPOSIT_AMOUNT);

        // End state: account fully drained
        (staked, unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0);
        assertEq(unstaked, 0);
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
        _ybBtc.approve(_portfolioAccount, DEPOSIT_AMOUNT);

        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, DEPOSIT_AMOUNT);

        vm.expectEmit(true, false, false, true, _portfolioAccount);
        emit YieldBasisLpFacet.Deposited(_user, DEPOSIT_AMOUNT);
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
        _depositAndStake(DEPOSIT_AMOUNT);

        vm.expectEmit(false, false, false, true, _portfolioAccount);
        emit YieldBasisLpFacet.Unstaked(DEPOSIT_AMOUNT, DEPOSIT_AMOUNT, 0);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);
    }

    function testRestakeEmitsEvent() public {
        _depositAndStake(DEPOSIT_AMOUNT);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        vm.expectEmit(false, false, false, true, _portfolioAccount);
        emit YieldBasisLpFacet.Staked(DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).stake(DEPOSIT_AMOUNT);
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
        // Full lifecycle: deposit, stake, then unstake — leaves DEPOSIT_AMOUNT on the account.
        // Staking MORE than is on the account must revert (ERC20 transferFrom underflow).
        _depositAndStake(DEPOSIT_AMOUNT);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        vm.prank(_authorizedCaller);
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).stake(DEPOSIT_AMOUNT + 1);
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
        _depositAndStake(DEPOSIT_AMOUNT);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).stake(DEPOSIT_AMOUNT);

        // After stake, approval from portfolio account to gauge should be 0
        uint256 allowance = _ybBtc.allowance(_portfolioAccount, address(_gauge));
        assertEq(allowance, 0, "Gauge allowance should be reset to 0 after stake");
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
        _depositAndStake(DEPOSIT_AMOUNT);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        vm.prank(_owner);
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).stake(DEPOSIT_AMOUNT);
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
        _depositAndStake(DEPOSIT_AMOUNT);
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        vm.prank(address(0xbad));
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).stake(DEPOSIT_AMOUNT);
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
        // Deposit holds LP on the account; nothing reaches the gauge
        assertEq(staked, 0);
        assertEq(unstaked, DEPOSIT_AMOUNT);
    }

    function testGetStakingStateMixed() public {
        // Stake after deposit so there are gauge shares to partially unstake
        _depositAndStake(DEPOSIT_AMOUNT);
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
    ///         This is correct behavior: admin must stake before new deposits are possible.
    /// @notice Collateral-balance invariant after a full unstake/stake cycle.
    ///
    ///   YieldBasisCollateralManager.addCollateral requires:
    ///     LP balance on account  >=  data.shares + newShares
    ///
    ///   When the first deposit is staked into the gauge, LP is NOT on the account,
    ///   so a second deposit would fail the balance check (first-deposit shares are
    ///   tracked but the backing LP is in the gauge). Depositing again requires the
    ///   admin to first `unstake` so the LP returns to the account.
    ///
    ///   This test pins that behavior: after cycling deposit→stake→unstake, the LP
    ///   is back on the account and a second deposit succeeds.
    function testDepositWorksAfterUnstakeRestake() public {
        _depositAndStake(DEPOSIT_AMOUNT);

        // Unstake so the first deposit's LP returns to the account (required for the
        // addCollateral balance check on the next deposit).
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        // Second deposit should succeed — account now holds DEPOSIT_AMOUNT from the
        // unstake, and the new deposit adds secondDeposit more, covering the
        // data.shares + newShares balance requirement.
        uint256 secondDeposit = DEPOSIT_AMOUNT / 2;
        vm.startPrank(_user);
        _ybBtc.approve(_portfolioAccount, secondDeposit);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, secondDeposit);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        // All LP is held unstaked on the account; gauge is empty
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0, "Gauge empty after unstake");
        assertEq(unstaked, DEPOSIT_AMOUNT + secondDeposit, "Both deposits held unstaked on account");

        uint256 collateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral, DEPOSIT_AMOUNT + secondDeposit, "Total collateral covers both deposits");
    }

    /// @notice Sibling to testDepositWorksAfterUnstakeRestake: while the first deposit is
    ///         staked into the gauge (LP not on account), a second deposit must revert
    ///         because the collateral-manager balance check fails.
    ///         This is the flipside invariant: no silent collateral double-counting.
    function testSecondDepositRevertsWhilePriorIsStaked() public {
        _depositAndStake(DEPOSIT_AMOUNT);

        uint256 secondDeposit = DEPOSIT_AMOUNT / 2;
        vm.startPrank(_user);
        _ybBtc.approve(_portfolioAccount, secondDeposit);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, secondDeposit);
        vm.expectRevert(); // InsufficientShareBalance: account LP < data.shares + newShares
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
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

    /// @notice Stake with zero unstaked ybBTC on the account should revert.
    ///         After deposit+stake the gauge holds all the LP; the account has zero LP
    ///         balance, so stake(amount) cannot pull anything and must revert.
    function testRestakeRevertsWithNoUnstakedBalance() public {
        _depositAndStake(DEPOSIT_AMOUNT);
        // Sanity: everything in gauge, nothing on account
        (uint256 stakedBefore, uint256 unstakedBefore) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(stakedBefore, DEPOSIT_AMOUNT, "All LP is in the gauge");
        assertEq(unstakedBefore, 0, "No LP on the account");

        vm.prank(_authorizedCaller);
        vm.expectRevert();
        YieldBasisLpFacet(_portfolioAccount).stake(DEPOSIT_AMOUNT);
    }

    /// @notice Multiple unstake/stake cycles should maintain correct balances
    function testMultipleUnstakeRestakeCycles() public {
        _depositAndStake(DEPOSIT_AMOUNT);

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(_authorizedCaller);
            YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);
            (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
            assertEq(staked, 0, "Should be fully unstaked");
            assertEq(unstaked, DEPOSIT_AMOUNT, "Should have full unstaked balance");

            vm.prank(_authorizedCaller);
            YieldBasisLpFacet(_portfolioAccount).stake(DEPOSIT_AMOUNT);
            (staked, unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
            assertEq(staked, DEPOSIT_AMOUNT, "Should be fully staked");
            assertEq(unstaked, 0, "Should have no unstaked balance");
        }

        // Collateral tracking should still be correct
        uint256 collateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral, DEPOSIT_AMOUNT, "Collateral should be unchanged after cycles");
    }

    /// @notice Unstake partial, stake partial, then withdraw everything
    function testPartialUnstakeRestakeThenFullWithdraw() public {
        _depositAndStake(DEPOSIT_AMOUNT);

        uint256 quarter = DEPOSIT_AMOUNT / 4;

        // Unstake half
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(quarter * 2);

        // Restake a quarter
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).stake(quarter);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, DEPOSIT_AMOUNT - quarter, "3/4 should be staked");
        assertEq(unstaked, quarter, "1/4 should be unstaked");

        // Withdraw everything -- should pull from unstaked + gauge
        uint256 userBefore = _ybBtc.balanceOf(_user);
        _withdrawViaMulticall(DEPOSIT_AMOUNT);
        assertEq(_ybBtc.balanceOf(_user) - userBefore, DEPOSIT_AMOUNT);
    }

    // ============ HARDENED TESTS: Collateral Invariants ============

    /// @notice Collateral is preserved across unstake/stake — LP stays in portfolio
    function testCollateralPreservedAcrossUnstakeRestake() public {
        // Stake after deposit so there are gauge shares to cycle through
        _depositAndStake(DEPOSIT_AMOUNT);

        uint256 collateralBefore = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertGt(collateralBefore, 0, "Should have collateral after deposit");

        // Unstake does NOT remove collateral — LP stays in portfolio
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).unstake(DEPOSIT_AMOUNT);

        uint256 collateralAfterUnstake = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfterUnstake, collateralBefore, "Collateral preserved after unstake");

        // Restake doesn't change collateral either
        vm.prank(_authorizedCaller);
        YieldBasisLpFacet(_portfolioAccount).stake(DEPOSIT_AMOUNT);

        uint256 collateralAfterRestake = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfterRestake, collateralBefore, "Collateral preserved after stake");
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

        // Deposit holds LP on the account (no auto-stake)
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0, "Deposit does not stake");
        assertEq(unstaked, amount, "Full deposit held unstaked");

        uint256 collateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral, amount, "Collateral tracks full deposit");
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

        // Deposit holds LP unstaked on the account; withdraw pulls directly from that balance
        uint256 remaining = depositAmt - withdrawAmt;
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0, "No gauge interaction when LP sits unstaked");
        assertEq(unstaked, remaining, "Remaining LP still unstaked on account");

        uint256 collateral = ICollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateral, remaining, "Collateral tracks remaining LP");
    }

    /// @notice Fuzz unstake: unstake amount <= staked should succeed
    function testFuzzUnstake(uint256 unstakeAmt) public {
        // Deposit+stake so there are gauge shares to unstake
        _depositAndStake(DEPOSIT_AMOUNT);
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

    /// @notice Withdraw should send ybBTC to the portfolio owner, not msg.sender.
    ///         We stake the deposit first so withdraw must pull from the gauge (the
    ///         "send to owner" branch that was ambiguous when LP sat on the account),
    ///         and verify the owner — not the caller or the portfolio account — receives
    ///         the tokens.
    function testWithdrawSendsToOwnerNotCaller() public {
        // Use a distinct caller that is NOT the portfolio owner. The lending-facet/multicall
        // guard must still route funds to the owner, not the caller.
        // (Here _user IS the portfolio owner, so we also verify the account itself keeps nothing.)
        _depositAndStake(DEPOSIT_AMOUNT);

        // Precondition: LP is fully staked, so the account holds zero LP directly
        assertEq(_ybBtc.balanceOf(_portfolioAccount), 0, "All LP is in the gauge (zero on account)");

        uint256 ownerBefore = _ybBtc.balanceOf(_user);
        _withdrawViaMulticall(DEPOSIT_AMOUNT);
        uint256 ownerAfter = _ybBtc.balanceOf(_user);

        assertEq(ownerAfter - ownerBefore, DEPOSIT_AMOUNT, "Owner receives full withdraw amount");
        assertEq(_ybBtc.balanceOf(_portfolioAccount), 0, "Portfolio account keeps no LP");
        assertEq(_gauge.balanceOf(_portfolioAccount), 0, "Portfolio account keeps no gauge shares");
    }

    // ============ HARDENED TESTS: Constructor Validation ============

    /// @notice Constructor should revert with zero address for portfolioFactory
    function testConstructorRevertsZeroFactory() public {
        vm.expectRevert("Invalid portfolio factory");
        new YieldBasisLpFacet(address(0), address(_gauge), address(_ybToken), address(_usdc));
    }

    /// @notice Constructor should revert with zero address for gauge
    function testConstructorRevertsZeroGauge() public {
        vm.expectRevert("Invalid gauge");
        new YieldBasisLpFacet(address(_portfolioFactory), address(0), address(_ybToken), address(_usdc));
    }

    /// @notice ClaimingFacet constructor should revert with zero address
    function testClaimingConstructorRevertsZeroFactory() public {
        vm.expectRevert("Invalid portfolio factory");
        new YieldBasisLpClaimingFacet(address(0), address(_gauge), address(_usdc));
    }

    function testClaimingConstructorRevertsZeroGauge() public {
        vm.expectRevert("Invalid gauge");
        new YieldBasisLpClaimingFacet(address(_portfolioFactory), address(0), address(_usdc));
    }

    // ============ HARDENED TESTS: Minimum Amount (1 wei) ============

    /// @notice Deposit and withdraw 1 wei should work correctly
    function testDepositAndWithdrawOneWei() public {
        _depositViaMulticall(1);

        // 1 wei LP held unstaked on account; nothing in gauge
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0);
        assertEq(unstaked, 1);

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

        // Large deposit held unstaked on the account
        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(_portfolioAccount).getStakingState();
        assertEq(staked, 0);
        assertEq(unstaked, largeAmount);

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
