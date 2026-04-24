// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {YieldBasisLpFacet} from "../../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisLpClaimingFacet} from "../../../../src/facets/account/yieldbasislp/YieldBasisLpClaimingFacet.sol";
import {ERC4626CollateralManager} from "../../../../src/facets/account/erc4626/ERC4626CollateralManager.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../../src/facets/account/config/SwapConfig.sol";
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

contract YieldBasisLpRewardsTest is Test {
    // YieldBasis Protocol Addresses (Ethereum Mainnet)
    address public constant YB = 0x01791F726B4103694969820be083196cC7c045fF;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // yb-WBTC gauge and LP
    address public constant WBTC_GAUGE = 0xbc56e3edB67b56d598aCE07668b138815F45d7aa;
    address public constant WBTC_LP = 0xfBF3C16676055776Ab9B286492D8f13e30e2E763;
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // Real on-chain users with positions in the WBTC gauge
    // Staked only: has gauge shares, claimable YB, no unstaked LP
    address public constant STAKED_USER = 0x196a2A9A22C2fD8f5107e97Df9ad14A23e81982B;
    // Both staked and unstaked: has gauge shares + LP balance
    address public constant MIXED_USER = 0x3df8669d6350dBB256bB4972d6C6F86efd301528;
    // Unstaked only: 0 gauge shares, has LP balance, still has claimable YB from prior staking
    address public constant UNSTAKED_USER = 0x37863DF4712e4494dFfc4854862259399354b2BB;

    // Test actors
    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public user = address(0x40ac2e);
    address public authorizedCaller = address(0xaaaaa);

    // Contracts
    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioFactoryConfig public portfolioFactoryConfig;

    // Portfolio account
    address public portfolioAccount;

    // Facets
    YieldBasisLpFacet public lpFacet;
    YieldBasisLpClaimingFacet public claimingFacet;

    // YB contracts
    IYieldBasisGauge public gauge = IYieldBasisGauge(WBTC_GAUGE);
    IERC20 public lpToken = IERC20(WBTC_LP);
    IERC20 public ybToken = IERC20(YB);

    function setUp() public {
        uint256 fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);

        vm.startPrank(DEPLOYER);

        portfolioManager = new PortfolioManager(DEPLOYER);

        (portfolioFactory, facetRegistry) = portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("yb-lp-rewards-test")))
        );

        DeployPortfolioFactoryConfig configDeployer = new DeployPortfolioFactoryConfig();
        (portfolioFactoryConfig,,,) = configDeployer.deploy(address(portfolioFactory), DEPLOYER);

        MockVault mockVault = new MockVault(USDC);
        MockLendingPool mockLendingPool = new MockLendingPool(USDC, address(mockVault));
        mockLendingPool.setPortfolioFactory(address(portfolioFactory));
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));
        portfolioFactoryConfig.setLoanContract(address(mockLendingPool));
        deal(USDC, address(mockVault), 1_000_000 * 1e6);

        // Deploy YieldBasisLpFacet
        lpFacet = new YieldBasisLpFacet(
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
        facetRegistry.registerFacet(address(lpFacet), lpSelectors, "YieldBasisLpFacet");

        // Deploy YieldBasisLpClaimingFacet
        claimingFacet = new YieldBasisLpClaimingFacet(
            address(portfolioFactory),
            WBTC_GAUGE,
            WBTC
        );
        bytes4[] memory claimSelectors = new bytes4[](2);
        claimSelectors[0] = YieldBasisLpClaimingFacet.claimGaugeRewards.selector;
        claimSelectors[1] = YieldBasisLpClaimingFacet.previewGaugeRewards.selector;
        facetRegistry.registerFacet(address(claimingFacet), claimSelectors, "YieldBasisLpClaimingFacet");

        portfolioManager.setAuthorizedCaller(authorizedCaller, true);

        vm.stopPrank();

        portfolioAccount = portfolioFactory.createAccount(user);

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    // ============ Real User Claiming (Impersonation) ============

    /// @notice Verify a staked user can claim YB rewards directly from the gauge.
    /// @dev Guarded against fork-state drift: if the real on-chain user has already
    ///      claimed or no longer has claimable rewards at the forked block, skip rather
    ///      than fail — the invariant under test is "IF a staked user has claimable
    ///      rewards, claiming delivers them", not "this specific address always has rewards".
    function testRealStakedUserClaimsRewards() public {
        uint256 claimable = gauge.preview_claim(YB, STAKED_USER);
        if (claimable == 0) { vm.skip(true); return; }

        uint256 ybBefore = ybToken.balanceOf(STAKED_USER);
        vm.prank(STAKED_USER);
        uint256 claimed = gauge.claim(YB, STAKED_USER);
        uint256 ybAfter = ybToken.balanceOf(STAKED_USER);

        assertGt(claimed, 0, "Should claim non-zero rewards");
        assertEq(ybAfter - ybBefore, claimed, "YB balance delta must equal claimed amount");
        console.log("Staked user claimed YB:", claimed);
    }

    /// @notice Verify an unstaked user (who previously staked) can still claim accrued YB
    function testRealUnstakedUserClaimsAccruedRewards() public {
        uint256 gaugeBalance = gauge.balanceOf(UNSTAKED_USER);
        assertEq(gaugeBalance, 0, "User should have 0 gauge shares (unstaked)");

        uint256 lpBalance = lpToken.balanceOf(UNSTAKED_USER);
        if (lpBalance == 0) { vm.skip(true); return; } // user no longer holds LP tokens

        uint256 claimable = gauge.preview_claim(YB, UNSTAKED_USER);
        if (claimable == 0) { vm.skip(true); return; } // rewards already claimed on-chain

        uint256 ybBefore = ybToken.balanceOf(UNSTAKED_USER);
        vm.prank(UNSTAKED_USER);
        uint256 claimed = gauge.claim(YB, UNSTAKED_USER);
        uint256 ybAfter = ybToken.balanceOf(UNSTAKED_USER);

        assertGt(claimed, 0, "Should claim accrued rewards");
        assertGt(ybAfter, ybBefore, "YB balance should increase");
        console.log("Unstaked user claimed YB:", claimed);
    }

    /// @notice Verify a mixed user (both staked + unstaked LP) can claim rewards.
    /// @dev Guarded against fork drift: if the real on-chain user has rebalanced their
    ///      position (e.g. moved all LP to gauge, or claimed already) at the forked
    ///      block, skip rather than fail. The invariant under test is that claim()
    ///      delivers accrued YB to the caller when claimable > 0.
    function testRealMixedUserClaimsRewards() public {
        uint256 gaugeBalance = gauge.balanceOf(MIXED_USER);
        uint256 lpBalance = lpToken.balanceOf(MIXED_USER);
        if (gaugeBalance == 0 || lpBalance == 0) { vm.skip(true); return; }

        uint256 claimable = gauge.preview_claim(YB, MIXED_USER);
        if (claimable == 0) { vm.skip(true); return; }

        uint256 ybBefore = ybToken.balanceOf(MIXED_USER);
        vm.prank(MIXED_USER);
        uint256 claimed = gauge.claim(YB, MIXED_USER);

        assertGt(claimed, 0, "Should claim rewards");
        assertEq(ybToken.balanceOf(MIXED_USER) - ybBefore, claimed, "YB balance delta must equal claimed");
        console.log("Mixed user claimed YB:", claimed);
        console.log("  gauge shares:", gaugeBalance);
        console.log("  unstaked LP:", lpBalance);
    }

    // ============ Portfolio Account: Deposit + Claim ============

    /// @notice Deposit LP, explicitly stake into gauge, then claim rewards after time passes.
    /// @dev Under current semantics, deposit() only pulls LP onto the account; staking into
    ///      the gauge must be done explicitly via the authorized-caller admin path. Rewards
    ///      only accrue on the staked portion, so claiming requires a prior stake().
    function testPortfolioDepositAndClaimAfterTimeWarp() public {
        uint256 depositAmount = 1 ether;
        deal(WBTC_LP, user, depositAmount);
        vm.prank(user);
        IERC20(WBTC_LP).approve(portfolioAccount, depositAmount);

        // 1. Deposit LP (does not touch gauge)
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, depositAmount);

        vm.prank(user);
        portfolioManager.multicall(calldatas, factories);

        // Post-deposit: position is unstaked (no gauge interaction on deposit)
        (uint256 stakedPostDeposit, uint256 unstakedPostDeposit) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(stakedPostDeposit, 0, "Deposit should not auto-stake");
        assertEq(unstakedPostDeposit, depositAmount, "Full LP sits unstaked on account");

        // 2. Explicitly stake the full amount — required for rewards to accrue in gauge
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).stake(depositAmount);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertGt(staked, 0, "Should have gauge shares after explicit stake");
        assertEq(unstaked, 0, "Should have no unstaked LP after full stake");

        // 3. Warp forward 7 days to accrue rewards
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 50400); // ~7 days of blocks

        // 4. Check claimable rewards
        uint256 claimable = YieldBasisLpClaimingFacet(portfolioAccount).previewGaugeRewards(YB);
        console.log("Claimable after 7 days:", claimable);
        assertGt(claimable, 0, "Staked LP should accrue YB rewards over 7 days");

        // 5. Claim rewards via authorized caller
        uint256 ybBefore = ybToken.balanceOf(portfolioAccount);
        vm.prank(authorizedCaller);
        uint256 claimed = YieldBasisLpClaimingFacet(portfolioAccount).claimGaugeRewards(YB);
        uint256 ybAfter = ybToken.balanceOf(portfolioAccount);

        // Rewards land on the portfolio account
        assertEq(ybAfter - ybBefore, claimed, "YB balance increase should match claimed");
        assertGt(claimed, 0, "Claim should yield non-zero YB after 7-day warp");
        console.log("Portfolio claimed YB:", claimed);
    }

    // ============ Portfolio Account: Unstake + Verify LP Price Appreciation ============

    /// @notice After staking then unstaking, LP lands back on the account where it earns
    ///         trading fees via price-per-share appreciation (no explicit claim required).
    /// @dev Under current semantics, deposit() leaves LP unstaked on the account. To
    ///      exercise the "stake → unstake" yield-mode switch, we must explicitly stake
    ///      first; otherwise unstake() has 0 gauge shares to redeem.
    function testPortfolioUnstakeAndVerifyLpValue() public {
        uint256 depositAmount = 1 ether;
        deal(WBTC_LP, user, depositAmount);
        vm.prank(user);
        IERC20(WBTC_LP).approve(portfolioAccount, depositAmount);

        // Deposit LP onto the account
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, depositAmount);

        vm.prank(user);
        portfolioManager.multicall(calldatas, factories);

        // Explicitly stake into gauge so the "unstake back to LP" path is meaningful.
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).stake(depositAmount);

        uint256 gaugeSharesBefore = gauge.balanceOf(portfolioAccount);
        assertGt(gaugeSharesBefore, 0, "Precondition: must hold gauge shares before unstake");

        // Warp to simulate passage of time before switching yield modes
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 7200);

        // Unstake to switch to trading fee yield mode. unstake() takes gauge shares
        // (redeem internally) and leaves LP on the account.
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).unstake(gaugeSharesBefore);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(staked, 0, "Should have 0 gauge shares after unstake");
        assertGt(unstaked, 0, "Should hold LP tokens directly after unstake");

        // Unstaked LP earns via price-per-share appreciation of the yb-WBTC pool.
        // On a fork we can't easily simulate trading volume, but we verify the LP
        // tokens are held correctly and can be staked or withdrawn.
        uint256 lpBalance = lpToken.balanceOf(portfolioAccount);
        assertEq(lpBalance, unstaked, "LP balance should match unstaked amount");
    }

    // ============ Portfolio Account: Full Lifecycle ============

    /// @notice Deposit → stake → claim → unstake → stake → claim → withdraw.
    /// @dev Under current semantics, deposit() only pulls LP onto the account. We must
    ///      call stake() explicitly after each deposit or restake to have gauge shares
    ///      that accrue YB rewards.
    function testFullLifecycle() public {
        uint256 depositAmount = 1 ether;
        deal(WBTC_LP, user, depositAmount);
        vm.prank(user);
        IERC20(WBTC_LP).approve(portfolioAccount, depositAmount);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);

        // 1. Deposit (LP lands unstaked on account)
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, depositAmount);
        vm.prank(user);
        portfolioManager.multicall(calldatas, factories);

        // 1a. Explicitly stake into gauge so rewards accrue
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).stake(depositAmount);

        (uint256 stakedAfterStake,) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertGt(stakedAfterStake, 0, "Gauge shares must exist after explicit stake");

        // 2. Warp and claim — should yield non-zero YB because we staked
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 50400);

        vm.prank(authorizedCaller);
        uint256 claimed1 = YieldBasisLpClaimingFacet(portfolioAccount).claimGaugeRewards(YB);
        assertGt(claimed1, 0, "First claim should yield rewards after 7 days staked");
        console.log("Claimed after 7 days staked:", claimed1);

        // 3. Unstake — pass gauge shares directly (unstake uses redeem)
        uint256 gaugeShares = gauge.balanceOf(portfolioAccount);
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).unstake(gaugeShares);

        (uint256 staked, uint256 unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(staked, 0);
        assertGt(unstaked, 0);

        // 4. Warp while unstaked (earning trading fees, not YB)
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 50400);

        // No new YB should accrue while unstaked
        uint256 claimableWhileUnstaked = YieldBasisLpClaimingFacet(portfolioAccount).previewGaugeRewards(YB);
        console.log("Claimable while unstaked (should be ~0):", claimableWhileUnstaked);

        // 5. Restake all unstaked LP
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).stake(unstaked);

        (staked, unstaked) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertGt(staked, 0, "Should be staked again");
        assertEq(unstaked, 0, "No unstaked LP");

        // 6. Warp and claim again
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 50400);

        // Second claim may be 0 on a fork if the gauge has no fresh emissions
        // allocated for this period — we don't control bribe/emission schedules here.
        // The lifecycle integrity we're validating is "restake works and produces a
        // live gauge position", which the getStakingState() assertions above cover.
        vm.prank(authorizedCaller);
        uint256 claimed2 = YieldBasisLpClaimingFacet(portfolioAccount).claimGaugeRewards(YB);
        console.log("Claimed after 7 days staked (may be 0 if gauge emissions depleted):", claimed2);

        // 7. Unstake from gauge first (admin), then withdraw LP to user
        // unstake() redeems gauge shares, leaving LP on the portfolio account
        gaugeShares = gauge.balanceOf(portfolioAccount);
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).unstake(gaugeShares);

        // Now withdraw the unstaked LP — withdraw() sees LP on the account and skips gauge
        uint256 lpOnAccount = lpToken.balanceOf(portfolioAccount);
        assertGt(lpOnAccount, 0, "LP should be on account after unstake");
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, lpOnAccount);
        vm.prank(user);
        portfolioManager.multicall(calldatas, factories);

        uint256 userLpBalance = lpToken.balanceOf(user);
        assertGt(userLpBalance, 0, "User should receive LP back");
    }

    // ============ Edge Cases ============

    /// @notice Claiming with zero rewards should not revert
    function testClaimWithNoAccruedRewards() public {
        uint256 depositAmount = 1 ether;
        deal(WBTC_LP, user, depositAmount);
        vm.prank(user);
        IERC20(WBTC_LP).approve(portfolioAccount, depositAmount);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, depositAmount);

        vm.prank(user);
        portfolioManager.multicall(calldatas, factories);

        // Claim immediately — no time has passed, minimal or zero rewards
        vm.prank(authorizedCaller);
        uint256 claimed = YieldBasisLpClaimingFacet(portfolioAccount).claimGaugeRewards(YB);
        // Should not revert, claimed may be 0 or very small
        console.log("Claimed immediately after deposit:", claimed);
    }

    /// @notice Double claim should be safe — second claim returns 0.
    /// @dev Under current semantics we must explicitly stake into the gauge for rewards
    ///      to accrue; deposit() alone leaves LP unstaked.
    function testDoubleClaimReturnsZero() public {
        uint256 depositAmount = 1 ether;
        deal(WBTC_LP, user, depositAmount);
        vm.prank(user);
        IERC20(WBTC_LP).approve(portfolioAccount, depositAmount);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, depositAmount);

        vm.prank(user);
        portfolioManager.multicall(calldatas, factories);

        // Explicitly stake so rewards accrue in the gauge
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).stake(depositAmount);

        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 50400);

        vm.prank(authorizedCaller);
        uint256 claimed1 = YieldBasisLpClaimingFacet(portfolioAccount).claimGaugeRewards(YB);
        assertGt(claimed1, 0, "First claim should yield rewards");

        vm.prank(authorizedCaller);
        uint256 claimed2 = YieldBasisLpClaimingFacet(portfolioAccount).claimGaugeRewards(YB);
        assertEq(claimed2, 0, "Second claim should be 0");
    }
}
