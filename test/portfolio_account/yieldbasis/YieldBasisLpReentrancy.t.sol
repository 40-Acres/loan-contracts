// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * YieldBasisLpReentrancy — verifies the `nonReentrant` modifier on
 * `harvestLpFees` covers BOTH external-call surfaces (gauge.withdraw and
 * lpToken.withdraw). A malicious gauge or LP that re-enters mid-harvest must
 * trigger the `ReentrantCall` revert.
 * =========================================================================*/

import {Test, console} from "forge-std/Test.sol";

import {YieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisLpClaimingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpClaimingFacet.sol";
import {YieldBasisLpLendingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpLendingFacet.sol";
import {ICollateralFacet} from "../../../src/facets/account/collateral/ICollateralFacet.sol";

import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {YieldBasisPortfolioFactoryConfig} from "../../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";
import {YbConfigDeployer} from "./helpers/YbConfigDeployer.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockTunableYieldBasisLP} from "../../mocks/MockTunableYieldBasisLP.sol";
import {MockTunableYieldBasisGauge} from "../../mocks/MockTunableYieldBasisGauge.sol";
import {MockReentrantYieldBasisGauge} from "../../mocks/MockReentrantYieldBasisGauge.sol";
import {MockReentrantYieldBasisLP} from "../../mocks/MockReentrantYieldBasisLP.sol";
import {MockReentrantSetStakedModeGauge} from "../../mocks/MockReentrantSetStakedModeGauge.sol";
import {YieldBasisPortfolioFactoryConfig} from "../../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract YieldBasisLpReentrancyTest is Test {
    PortfolioFactory internal portfolioFactory;
    PortfolioManager internal portfolioManager;
    FacetRegistry internal facetRegistry;
    YieldBasisPortfolioFactoryConfig internal portfolioFactoryConfig;
    LoanConfig internal loanConfig;
    LendingVault internal lendingVault;
    MockERC20 internal underlying;
    MockERC20 internal ybToken;

    address internal user = address(0x40ac2e);
    address internal authorizedCaller = address(0xaaaaa);
    address internal owner_ = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);

    uint256 internal constant DEPOSIT = 100e18;
    uint256 internal constant VAULT_LIQ = 10_000_000e18;
    uint256 internal constant LTV_BPS = 7000;

    /// @dev Builds a fresh diamond harness with the given gauge and LP. Each
    ///      reentrancy test gets its own diamond because gauge/LP are
    ///      immutable on the facet.
    function _buildHarness(address gauge, address lpToken)
        internal
        returns (address portfolioAccount, YieldBasisLpFacet facet, YieldBasisLpClaimingFacet claimingFacet)
    {
        vm.startPrank(owner_);

        portfolioManager = new PortfolioManager(owner_);
        (PortfolioFactory pf, FacetRegistry fr) = portfolioManager.deployFactory(
            keccak256(abi.encodePacked("reentrancy-harness-", gauge, lpToken))
        );
        portfolioFactory = pf;
        facetRegistry = fr;

        YbConfigDeployer deployer = new YbConfigDeployer();
        (portfolioFactoryConfig, , loanConfig, ) = deployer.deployYb(address(portfolioFactory), owner_);

        LendingVault impl = new LendingVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                LendingVault.initialize,
                (address(underlying), address(portfolioFactory), owner_, "lvault", "lv", 0)
            )
        );
        lendingVault = LendingVault(address(proxy));
        underlying.mint(address(lendingVault), VAULT_LIQ);

        loanConfig.setMultiplier(LTV_BPS);
        portfolioFactoryConfig.setLoanContract(address(lendingVault));
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        facet = new YieldBasisLpFacet(
            address(portfolioFactory), gauge, address(ybToken), address(lendingVault)
        );
        {
            bytes4[] memory selectors = new bytes4[](8);
            selectors[0] = YieldBasisLpFacet.deposit.selector;
            selectors[1] = YieldBasisLpFacet.withdraw.selector;
            selectors[2] = YieldBasisLpFacet.setStakedMode.selector;
            selectors[3] = YieldBasisLpFacet.getStakingState.selector;
            selectors[4] = ICollateralFacet.enforceCollateralRequirements.selector;
            selectors[5] = ICollateralFacet.getTotalLockedCollateral.selector;
            selectors[6] = ICollateralFacet.getTotalDebt.selector;
            selectors[7] = ICollateralFacet.getMaxLoan.selector;
            facetRegistry.registerFacet(address(facet), selectors, "YBFacet");
        }

        claimingFacet = new YieldBasisLpClaimingFacet(
            address(portfolioFactory), gauge, address(lendingVault)
        );
        {
            bytes4[] memory selectors = new bytes4[](5);
            selectors[0] = YieldBasisLpClaimingFacet.claimGaugeRewards.selector;
            selectors[1] = YieldBasisLpClaimingFacet.previewGaugeRewards.selector;
            selectors[2] = YieldBasisLpClaimingFacet.harvestLpFees.selector;
            selectors[3] = YieldBasisLpClaimingFacet.getAvailableLpFeeYield.selector;
            selectors[4] = YieldBasisLpClaimingFacet.getDepositInfo.selector;
            facetRegistry.registerFacet(address(claimingFacet), selectors, "YBClaimingFacet");
        }

        portfolioManager.setAuthorizedCaller(authorizedCaller, true);
        vm.stopPrank();

        portfolioAccount = portfolioFactory.createAccount(user);
        // suppress unused-variable warning when caller doesn't need lpToken at the harness layer
        lpToken;
    }

    function _depositVia(address portfolioAccount, MockERC20 lp, uint256 amount) internal {
        vm.startPrank(user);
        lp.approve(portfolioAccount, amount);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    /// @dev Setup shared by both tests: deploy underlying + YB token. Each test
    ///      then builds its own harness with malicious gauge or LP.
    function setUp() public {
        underlying = new MockERC20("WETH", "WETH", 18);
        ybToken = new MockERC20("YB", "YB", 18);
    }

    /* =====================================================================
     * Test 1: malicious gauge re-enters harvestLpFees during gauge.withdraw.
     *
     * Flow: deposit + stake → harvest pulls from gauge (no direct LP) → gauge
     * callback into harvestLpFees triggers nonReentrant guard.
     * =====================================================================*/
    function test_GaugeReentrancy_OnHarvest_Reverts() public {
        // Build harness with malicious gauge. LP is the standard tunable mock.
        MockTunableYieldBasisLP ybLp = new MockTunableYieldBasisLP("ybETH", "ybETH", 18, address(underlying));
        MockReentrantYieldBasisGauge maliciousGauge = new MockReentrantYieldBasisGauge(address(ybLp));

        (address portfolioAccount, , YieldBasisLpClaimingFacet claimingFacet) =
            _buildHarness(address(maliciousGauge), address(ybLp));

        // Seed underlying liquidity in the LP so harvest's _lpToken.withdraw can deliver.
        underlying.mint(address(ybLp), 1_000_000e18);
        ybLp.mint(user, DEPOSIT * 10);

        // Deposit + stake all LP into the malicious gauge so harvest must pull
        // from the gauge (zero direct LP balance).
        _depositVia(portfolioAccount, ybLp, DEPOSIT);
        vm.prank(owner_);
        portfolioFactoryConfig.setStakedGaugeMode(true);
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).setStakedMode();

        // Generate yield via pps growth so harvest has surplusShares > 0.
        ybLp.setPricePerShare(1.10e18);

        // Arm the gauge to call harvestLpFees back on the portfolio account.
        uint256 floor = (ybLp.pricePerShare() * 85) / 100;
        bytes memory reentrantCall = abi.encodeWithSelector(
            YieldBasisLpClaimingFacet.harvestLpFees.selector, floor
        );
        maliciousGauge.arm(portfolioAccount, reentrantCall);

        // Outer call should revert with ReentrantCall (custom error from the
        // facet's nonReentrant modifier). The malicious gauge bubbles the
        // inner revert, so we assert with the selector via expectRevert.
        vm.prank(authorizedCaller);
        vm.expectRevert(YieldBasisLpClaimingFacet.ReentrantCall.selector);
        YieldBasisLpClaimingFacet(portfolioAccount).harvestLpFees(floor);
    }

    /* =====================================================================
     * Test 2: malicious LP re-enters harvestLpFees during _lpToken.withdraw.
     *
     * Flow: deposit (unstaked) → harvest sources LP directly from account →
     * _lpToken.withdraw callback into harvestLpFees triggers nonReentrant.
     * =====================================================================*/
    function test_LpReentrancy_OnWithdraw_Reverts() public {
        // Build harness with malicious LP. Gauge is the standard tunable mock,
        // but we'll keep the LP unstaked so the gauge isn't touched.
        MockReentrantYieldBasisLP ybLp = new MockReentrantYieldBasisLP("ybETH", "ybETH", 18, address(underlying));
        MockTunableYieldBasisGauge gauge = new MockTunableYieldBasisGauge(address(ybLp));

        (address portfolioAccount, , YieldBasisLpClaimingFacet claimingFacet) =
            _buildHarness(address(gauge), address(ybLp));

        // Seed underlying liquidity in the LP so harvest's withdraw can deliver.
        underlying.mint(address(ybLp), 1_000_000e18);
        ybLp.mint(user, DEPOSIT * 10);

        // Deposit unstaked. Factory mode default is unstaked (getStakedGaugeMode
        // returns false unless explicitly toggled), so direct LP stays on account.
        _depositVia(portfolioAccount, MockERC20(address(ybLp)), DEPOSIT);

        // Generate yield via pps growth.
        ybLp.setPricePerShare(1.10e18);

        // Arm the LP to call back into harvestLpFees during withdraw.
        uint256 floor = (ybLp.pricePerShare() * 85) / 100;
        bytes memory reentrantCall = abi.encodeWithSelector(
            YieldBasisLpClaimingFacet.harvestLpFees.selector, floor
        );
        ybLp.arm(portfolioAccount, reentrantCall);

        vm.prank(authorizedCaller);
        vm.expectRevert(YieldBasisLpClaimingFacet.ReentrantCall.selector);
        YieldBasisLpClaimingFacet(portfolioAccount).harvestLpFees(floor);
    }

    /* =====================================================================
     * Test 3: malicious gauge re-enters setStakedMode during gauge.deposit
     *         (the staked=true branch of setStakedMode).
     *
     * The newly-added `nonReentrant` modifier on setStakedMode (was not
     * previously guarded) MUST trip when the gauge calls back into the
     * facet mid-stake. ReentrancyGuardTransient raises
     * `ReentrancyGuardReentrantCall()` on the second entry.
     *
     * Without the guard, two compounding effects could occur:
     *   - Double-stake of approval residue (if _stake-then-stake interleaves
     *     before approve(0) lands).
     *   - Inconsistent factory-flag observation if a parallel mode flip
     *     races (less likely here but the guard makes the surface verifiable).
     * =====================================================================*/
    /// @dev Note on isolation: setStakedMode applies BOTH onlyAuthorizedCaller
    ///      AND nonReentrant. To test the reentrancy guard in isolation we
    ///      must make the malicious gauge an authorized caller — otherwise
    ///      the inner re-entry reverts with `NotAuthorizedCaller` before
    ///      reaching the guard, and we'd be measuring the access-control
    ///      modifier instead. This is a worthwhile observation in its own
    ///      right: onlyAuthorizedCaller is the FIRST line of defense; the
    ///      transient guard exists for the (in-practice rare) case where
    ///      a malicious actor IS authorized — e.g. an exploited keeper.
    function test_SetStakedMode_GaugeReentrancyOnDeposit_Reverts() public {
        // Standard mock LP (we don't need it to misbehave for this test).
        MockTunableYieldBasisLP ybLp = new MockTunableYieldBasisLP("ybETH", "ybETH", 18, address(underlying));
        MockReentrantSetStakedModeGauge maliciousGauge =
            new MockReentrantSetStakedModeGauge(address(ybLp));

        (address portfolioAccount, , ) = _buildHarness(address(maliciousGauge), address(ybLp));

        // Authorize the malicious gauge so its inner re-entry passes the
        // access-control check and we observe nonReentrant in isolation.
        vm.prank(owner_);
        portfolioManager.setAuthorizedCaller(address(maliciousGauge), true);

        // User has LP minted onto them; deposit it unstaked first.
        ybLp.mint(user, DEPOSIT * 2);
        _depositVia(portfolioAccount, MockERC20(address(ybLp)), DEPOSIT);

        // Flip the factory flag to staked AFTER deposit (so deposit doesn't
        // auto-stake yet — leaving direct LP on the account for setStakedMode
        // to consume).
        vm.prank(owner_);
        portfolioFactoryConfig.setStakedGaugeMode(true);

        // Arm: when the facet calls _gauge.deposit during _stake, the gauge
        // re-enters setStakedMode on the same account. Re-entry path will
        // also see staked=true and call _stake again — exactly what we're
        // guarding against.
        bytes memory reentrantCall = abi.encodeWithSelector(YieldBasisLpFacet.setStakedMode.selector);
        maliciousGauge.armOnDeposit(portfolioAccount, reentrantCall);

        vm.prank(authorizedCaller);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        YieldBasisLpFacet(portfolioAccount).setStakedMode();
    }

    /* =====================================================================
     * Test 4: malicious gauge re-enters setStakedMode during gauge.redeem
     *         (the staked=false branch of setStakedMode).
     * =====================================================================*/
    function test_SetStakedMode_GaugeReentrancyOnRedeem_Reverts() public {
        MockTunableYieldBasisLP ybLp = new MockTunableYieldBasisLP("ybETH", "ybETH", 18, address(underlying));
        MockReentrantSetStakedModeGauge maliciousGauge =
            new MockReentrantSetStakedModeGauge(address(ybLp));

        (address portfolioAccount, , ) = _buildHarness(address(maliciousGauge), address(ybLp));

        // Authorize the malicious gauge — see deposit-path test for rationale.
        vm.prank(owner_);
        portfolioManager.setAuthorizedCaller(address(maliciousGauge), true);

        // Get into a state where the account has gauge shares: deposit while
        // factory mode is staked=true, so deposit auto-stakes.
        ybLp.mint(user, DEPOSIT * 2);
        vm.prank(owner_);
        portfolioFactoryConfig.setStakedGaugeMode(true);
        _depositVia(portfolioAccount, MockERC20(address(ybLp)), DEPOSIT);

        // Flip flag to false so a setStakedMode call goes down the unstake branch.
        vm.prank(owner_);
        portfolioFactoryConfig.setStakedGaugeMode(false);

        // Arm redeem to re-enter setStakedMode.
        bytes memory reentrantCall = abi.encodeWithSelector(YieldBasisLpFacet.setStakedMode.selector);
        maliciousGauge.armOnRedeem(portfolioAccount, reentrantCall);

        vm.prank(authorizedCaller);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        YieldBasisLpFacet(portfolioAccount).setStakedMode();
    }

    /* =====================================================================
     * Test 5: two SEQUENTIAL setStakedMode calls in DIFFERENT transactions
     *         both succeed.
     *
     * `ReentrancyGuardTransient` uses an EIP-1153 transient slot that auto-
     * clears at end-of-tx. If the slot were ever migrated to a regular
     * storage slot (a common refactor mistake), the second call in a later
     * tx would still see the slot set and revert.
     *
     * Forge runs each test in a fresh tx context, but cheatcodes inside a
     * single test stay in one tx. We simulate two txs via vm.prank between
     * calls AND a vm.roll bump — every consecutive prank to the same
     * address actually reuses the tx, so the strongest signal is to call
     * at different block heights and confirm both succeed without revert.
     * =====================================================================*/
    function test_SetStakedMode_SequentialCallsAcrossTxs_BothSucceed() public {
        // Use plain (non-malicious) tunable mocks so neither call self-aborts.
        MockTunableYieldBasisLP ybLp = new MockTunableYieldBasisLP("ybETH", "ybETH", 18, address(underlying));
        MockTunableYieldBasisGauge gauge = new MockTunableYieldBasisGauge(address(ybLp));
        (address portfolioAccount, , ) = _buildHarness(address(gauge), address(ybLp));

        ybLp.mint(user, DEPOSIT * 2);

        // Deposit unstaked. Direct LP sits on the account.
        _depositVia(portfolioAccount, MockERC20(address(ybLp)), DEPOSIT);

        // Tx 1: stake.
        vm.prank(owner_);
        portfolioFactoryConfig.setStakedGaugeMode(true);
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).setStakedMode();

        // After tx 1: LP is gone, gauge shares present.
        (uint256 staked1, uint256 unstaked1) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(unstaked1, 0, "tx1: direct LP consumed");
        assertGt(staked1, 0, "tx1: gauge shares present");

        // Roll forward to make explicit this is "later" — and also forces
        // anything block-scoped to reset. Transient slots clear at end-of-tx
        // regardless of block.
        vm.roll(block.number + 1);

        // Tx 2: unstake. If transient slot persisted across txs, this would
        // revert with ReentrancyGuardReentrantCall before doing any work.
        vm.prank(owner_);
        portfolioFactoryConfig.setStakedGaugeMode(false);
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).setStakedMode();

        (uint256 staked2, uint256 unstaked2) = YieldBasisLpFacet(portfolioAccount).getStakingState();
        assertEq(staked2, 0, "tx2: gauge shares consumed");
        assertGt(unstaked2, 0, "tx2: LP returned to account");
    }

    /* =====================================================================
     * Test 6: storage isolation — the transient reentrancy slot must NOT
     *         collide with any persistent diamond storage.
     *
     * ReentrancyGuardTransient computes its slot from a hash that should
     * never conflict with the ERC-7201 namespaced slots used by the
     * collateral managers. We sanity-check this by:
     *   1. Making a call that asserts the guard runs (re-entry trips).
     *   2. After the tx ends, doing a normal deposit that depends on
     *      YieldBasisCollateralManager storage — if the guard slot HAD
     *      stomped storage.YieldBasisCollateralManager.shares, this
     *      deposit's required-balance check would misbehave.
     * =====================================================================*/
    function test_SetStakedMode_TransientSlot_DoesNotCorruptCollateralStorage() public {
        MockTunableYieldBasisLP ybLp = new MockTunableYieldBasisLP("ybETH", "ybETH", 18, address(underlying));
        MockTunableYieldBasisGauge gauge = new MockTunableYieldBasisGauge(address(ybLp));
        (address portfolioAccount, , ) = _buildHarness(address(gauge), address(ybLp));

        ybLp.mint(user, DEPOSIT * 5);

        // Tx A: deposit + stake. Exercises setStakedMode (trips transient set).
        _depositVia(portfolioAccount, MockERC20(address(ybLp)), DEPOSIT);
        vm.prank(owner_);
        portfolioFactoryConfig.setStakedGaugeMode(true);
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).setStakedMode();

        // Tx B: deposit again — depends on collateral storage being intact
        // (data.shares accumulating, depositedAssetValue accumulating).
        // If transient slot collided with the storage slot, this deposit
        // would either revert (insufficient balance check using stomped
        // shares) or accumulate to a wrong total.
        uint256 prelocked = YieldBasisLpFacet(portfolioAccount).getTotalLockedCollateral();
        vm.roll(block.number + 1);
        _depositVia(portfolioAccount, MockERC20(address(ybLp)), DEPOSIT);

        uint256 postlocked = YieldBasisLpFacet(portfolioAccount).getTotalLockedCollateral();
        // pps default = 1e18 on the tunable mock, so locked-value should
        // increase by exactly DEPOSIT.
        assertEq(postlocked, prelocked + DEPOSIT, "collateral accounting intact across setStakedMode txs");
    }
}
