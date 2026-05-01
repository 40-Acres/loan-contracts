// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

// YB facets
import {YieldBasisLpFacet} from "../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisLpClaimingFacet} from "../../src/facets/account/yieldbasislp/YieldBasisLpClaimingFacet.sol";
import {YieldBasisLpLendingFacet} from "../../src/facets/account/yieldbasislp/YieldBasisLpLendingFacet.sol";
import {YieldBasisCollateralManager} from "../../src/facets/account/yieldbasislp/YieldBasisCollateralManager.sol";
import {ICollateralFacet} from "../../src/facets/account/collateral/ICollateralFacet.sol";

// Infra
import {PortfolioFactory} from "../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../src/accounts/FacetRegistry.sol";
import {LoanConfig} from "../../src/facets/account/config/LoanConfig.sol";
import {YieldBasisPortfolioFactoryConfig} from "../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";
import {YbConfigDeployer} from "../portfolio_account/yieldbasis/helpers/YbConfigDeployer.sol";
import {LendingVault} from "../../src/facets/account/vault/LendingVault.sol";
import {HarvestFloor85} from "../portfolio_account/yieldbasis/helpers/HarvestFloor85.sol";
import {IYieldBasisLP} from "../../src/interfaces/IYieldBasisLP.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockTunableYieldBasisLP} from "../mocks/MockTunableYieldBasisLP.sol";
import {MockTunableYieldBasisGauge} from "../mocks/MockTunableYieldBasisGauge.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SequencerLivenessLib} from "../../src/oracle/SequencerLivenessLib.sol";
import {SequencerLivenessCheck} from "../../src/oracle/SequencerLivenessCheck.sol";
import {MockChainlinkSequencerUptimeFeed} from "../mocks/MockChainlinkSequencerUptimeFeed.sol";

/**
 * @title YbWithdrawAndHarvestGatingTest
 * @dev Tests two YieldBasis-specific properties of the sequencer-uptime guard:
 *      1. withdraw() reverts with SequencerDown BEFORE the (potentially inflated)
 *         pricePerShare is consulted — the lending-review mitigation #2 rationale
 *         lock-in for diverging from Aave's "withdraw is ungated" stance.
 *      2. harvestLpFees() is INTENTIONALLY NOT GATED — even with a stale-high
 *         pricePerShare, the user-favorable harvest path remains open. This is
 *         the asymmetry encoded in plan §0 answer 5 + risk row 10.
 *      3. Multi-config independence: an opt-out factory still functions while a
 *         guarded factory is locked out.
 */
contract YbWithdrawAndHarvestGatingTest is Test, HarvestFloor85 {
    YieldBasisLpFacet internal facet;
    YieldBasisLpClaimingFacet internal claimingFacet;
    YieldBasisLpLendingFacet internal lendingFacet;

    PortfolioFactory internal portfolioFactory;
    PortfolioManager internal portfolioManager;
    FacetRegistry internal facetRegistry;
    YieldBasisPortfolioFactoryConfig internal portfolioFactoryConfig;
    LoanConfig internal loanConfig;
    LendingVault internal lendingVault;

    MockTunableYieldBasisLP internal ybLp;
    MockERC20 internal underlying;
    MockERC20 internal ybToken;
    MockTunableYieldBasisGauge internal gauge;

    // Second factory with no guard — multi-config independence test.
    PortfolioFactory internal portfolioFactory2;
    FacetRegistry internal facetRegistry2;
    YieldBasisPortfolioFactoryConfig internal portfolioFactoryConfig2;
    LoanConfig internal loanConfig2;
    LendingVault internal lendingVault2;
    YieldBasisLpFacet internal facet2;
    YieldBasisLpLendingFacet internal lendingFacet2;
    address internal portfolioAccount2;

    // Guard
    SequencerLivenessCheck internal guard;
    MockChainlinkSequencerUptimeFeed internal feed;

    address internal user = address(0x40ac2e);
    address internal authorizedCaller = address(0xaaaaa);
    address internal owner_ = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal portfolioAccount;

    uint256 internal constant DEPOSIT = 100e18;
    uint256 internal constant VAULT_LIQ = 10_000_000e18;
    uint256 internal constant LTV_BPS = 7000;
    uint256 internal constant GRACE = 1 hours;

    function setUp() public {
        vm.startPrank(owner_);

        portfolioManager = new PortfolioManager(owner_);

        // ── Factory 1 (guarded) ─────────────────────────────────────────
        (PortfolioFactory pf, FacetRegistry fr) = portfolioManager.deployFactory(keccak256("yb-guard-1"));
        portfolioFactory = pf;
        facetRegistry = fr;

        YbConfigDeployer deployer = new YbConfigDeployer();
        (portfolioFactoryConfig, , loanConfig, ) = deployer.deployYb(address(portfolioFactory), owner_);

        underlying = new MockERC20("WETH", "WETH", 18);
        ybLp = new MockTunableYieldBasisLP("ybETH", "ybETH", 18, address(underlying));
        ybToken = new MockERC20("YB", "YB", 18);
        gauge = new MockTunableYieldBasisGauge(address(ybLp));

        LendingVault impl = new LendingVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                LendingVault.initialize,
                (address(underlying), address(portfolioFactory), owner_, "lvault", "lv", 8000, 0)
            )
        );
        lendingVault = LendingVault(address(proxy));
        underlying.mint(address(lendingVault), VAULT_LIQ);

        loanConfig.setMultiplier(LTV_BPS);
        portfolioFactoryConfig.setLoanContract(address(lendingVault));
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        // facet
        facet = new YieldBasisLpFacet(
            address(portfolioFactory), address(gauge), address(ybToken), address(lendingVault)
        );
        bytes4[] memory facetSelectors = new bytes4[](8);
        facetSelectors[0] = YieldBasisLpFacet.deposit.selector;
        facetSelectors[1] = YieldBasisLpFacet.withdraw.selector;
        facetSelectors[2] = YieldBasisLpFacet.setStakedMode.selector;
        facetSelectors[3] = YieldBasisLpFacet.getStakingState.selector;
        facetSelectors[4] = ICollateralFacet.enforceCollateralRequirements.selector;
        facetSelectors[5] = ICollateralFacet.getTotalLockedCollateral.selector;
        facetSelectors[6] = ICollateralFacet.getTotalDebt.selector;
        facetSelectors[7] = ICollateralFacet.getMaxLoan.selector;
        facetRegistry.registerFacet(address(facet), facetSelectors, "YBFacet");

        claimingFacet = new YieldBasisLpClaimingFacet(
            address(portfolioFactory), address(gauge), address(lendingVault)
        );
        bytes4[] memory claimingSelectors = new bytes4[](5);
        claimingSelectors[0] = YieldBasisLpClaimingFacet.claimGaugeRewards.selector;
        claimingSelectors[1] = YieldBasisLpClaimingFacet.previewGaugeRewards.selector;
        claimingSelectors[2] = YieldBasisLpClaimingFacet.harvestLpFees.selector;
        claimingSelectors[3] = YieldBasisLpClaimingFacet.getAvailableLpFeeYield.selector;
        claimingSelectors[4] = YieldBasisLpClaimingFacet.getDepositInfo.selector;
        facetRegistry.registerFacet(address(claimingFacet), claimingSelectors, "YBClaimingFacet");

        lendingFacet = new YieldBasisLpLendingFacet(
            address(portfolioFactory), address(lendingVault), address(gauge)
        );
        bytes4[] memory lendingSelectors = new bytes4[](2);
        lendingSelectors[0] = YieldBasisLpLendingFacet.borrow.selector;
        lendingSelectors[1] = YieldBasisLpLendingFacet.pay.selector;
        facetRegistry.registerFacet(address(lendingFacet), lendingSelectors, "YBLendingFacet");

        portfolioManager.setAuthorizedCaller(authorizedCaller, true);

        // ── Factory 2 (opt-out) — registers same facets independently ───
        (PortfolioFactory pf2, FacetRegistry fr2) = portfolioManager.deployFactory(keccak256("yb-optout-2"));
        portfolioFactory2 = pf2;
        facetRegistry2 = fr2;

        (portfolioFactoryConfig2, , loanConfig2, ) = deployer.deployYb(address(portfolioFactory2), owner_);

        LendingVault impl2 = new LendingVault();
        ERC1967Proxy proxy2 = new ERC1967Proxy(
            address(impl2),
            abi.encodeCall(
                LendingVault.initialize,
                (address(underlying), address(portfolioFactory2), owner_, "lvault2", "lv2", 8000, 0)
            )
        );
        lendingVault2 = LendingVault(address(proxy2));
        underlying.mint(address(lendingVault2), VAULT_LIQ);

        loanConfig2.setMultiplier(LTV_BPS);
        portfolioFactoryConfig2.setLoanContract(address(lendingVault2));
        portfolioFactory2.setPortfolioFactoryConfig(address(portfolioFactoryConfig2));

        facet2 = new YieldBasisLpFacet(
            address(portfolioFactory2), address(gauge), address(ybToken), address(lendingVault2)
        );
        bytes4[] memory facetSelectors2 = new bytes4[](8);
        facetSelectors2[0] = YieldBasisLpFacet.deposit.selector;
        facetSelectors2[1] = YieldBasisLpFacet.withdraw.selector;
        facetSelectors2[2] = YieldBasisLpFacet.setStakedMode.selector;
        facetSelectors2[3] = YieldBasisLpFacet.getStakingState.selector;
        facetSelectors2[4] = ICollateralFacet.enforceCollateralRequirements.selector;
        facetSelectors2[5] = ICollateralFacet.getTotalLockedCollateral.selector;
        facetSelectors2[6] = ICollateralFacet.getTotalDebt.selector;
        facetSelectors2[7] = ICollateralFacet.getMaxLoan.selector;
        facetRegistry2.registerFacet(address(facet2), facetSelectors2, "YBFacet2");

        lendingFacet2 = new YieldBasisLpLendingFacet(
            address(portfolioFactory2), address(lendingVault2), address(gauge)
        );
        bytes4[] memory lendingSelectors2 = new bytes4[](2);
        lendingSelectors2[0] = YieldBasisLpLendingFacet.borrow.selector;
        lendingSelectors2[1] = YieldBasisLpLendingFacet.pay.selector;
        facetRegistry2.registerFacet(address(lendingFacet2), lendingSelectors2, "YBLendingFacet2");

        // ── Guard, attached only to factory 1 config ────────────────────
        feed = new MockChainlinkSequencerUptimeFeed();
        feed.setStatus(0, block.timestamp - GRACE - 1);
        guard = new SequencerLivenessCheck(owner_, address(feed), GRACE, 150);

        portfolioFactoryConfig.setSequencerLivenessCheck(address(guard));
        // Factory 2 explicitly left at address(0) — opt-out.

        vm.stopPrank();

        portfolioAccount = portfolioFactory.createAccount(user);
        portfolioAccount2 = portfolioFactory2.createAccount(user);

        ybLp.mint(user, DEPOSIT * 10);
        underlying.mint(address(ybLp), 1_000_000e18);

        vm.label(address(ybLp), "ybLp");
        vm.label(address(gauge), "gauge");
        vm.label(address(underlying), "underlying");
        vm.label(portfolioAccount, "portfolioAccount(guarded)");
        vm.label(portfolioAccount2, "portfolioAccount(opt-out)");
    }

    // ─────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────

    function _deposit(PortfolioFactory factory_, address pa, uint256 amount) internal {
        vm.startPrank(user);
        ybLp.approve(pa, amount);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(factory_);
        cd[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    function _borrow(PortfolioFactory factory_, uint256 amount) internal {
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(factory_);
        cd[0] = abi.encodeWithSelector(YieldBasisLpLendingFacet.borrow.selector, amount);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    function _withdrawExpectRevert(uint256 amount, bytes4 selector) internal {
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, amount);
        vm.expectRevert(selector);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    function _markDown() internal {
        feed.setStatus(1, block.timestamp - GRACE - 1);
    }

    function _floor85Local() internal view returns (uint256) {
        return _floor85(IYieldBasisLP(address(ybLp)));
    }

    // ─────────────────────────────────────────────────────────
    // E. Withdraw rationale: SequencerDown reverts BEFORE pricePerShare is trusted.
    // ─────────────────────────────────────────────────────────

    /**
     * @dev This test pins the rationale for diverging from Aave's "withdraw is
     *      ungated" stance. If we were to leave withdraw ungated (Aave-style),
     *      a user could withdraw against an inflated, stale pricePerShare during
     *      the post-recovery grace window — extracting more underlying value than
     *      their LP backed at the true post-recovery quote.
     *
     *      The protection here: assertUp() is the FIRST statement in withdraw(),
     *      so even a wildly-inflated pricePerShare cannot be consulted while the
     *      sequencer-uptime guard reports down. If a future reader wonders why
     *      we diverge from Aave, this test is the answer — DO NOT remove the
     *      gate without revisiting the divergence rationale in lending-review.
     */
    function test_withdraw_revertsOnSequencerDown_beforeStaleHighPriceConsulted() public {
        _deposit(portfolioFactory, portfolioAccount, DEPOSIT);

        // Borrow against the LP at honest 1.0 pps so we have some debt.
        _borrow(portfolioFactory, 50e18);

        // Adversarial scenario: sequencer goes down, then pricePerShare gets
        // inflated (the "stale-high" oracle scenario). If withdraw were ungated,
        // it would consult this inflated pps to compute collateral value at the
        // post-debt-removal LTV check.
        _markDown();
        ybLp.setPricePerShare(10e18); // wildly inflated

        // withdraw must short-circuit on SequencerDown — never reaches the
        // collateral manager / pricePerShare-dependent code path.
        _withdrawExpectRevert(DEPOSIT / 2, SequencerLivenessLib.SequencerDown.selector);

        // Sanity: the inflated pps was indeed set (so this isn't a no-op).
        assertEq(IYieldBasisLP(address(ybLp)).pricePerShare(), 10e18);
    }

    function test_withdraw_succeedsWhenSequencerUp() public {
        _deposit(portfolioFactory, portfolioAccount, DEPOSIT);
        // No borrow, default up state.
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(YieldBasisLpFacet.withdraw.selector, DEPOSIT / 2);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();

        assertEq(ybLp.balanceOf(user), DEPOSIT * 10 - DEPOSIT + DEPOSIT / 2);
    }

    // ─────────────────────────────────────────────────────────
    // F. Harvest is NOT gated — asymmetry confirmation.
    // ─────────────────────────────────────────────────────────

    /**
     * @dev harvestLpFees is intentionally ungated (user-favorable). Even with the
     *      sequencer "down" the path remains open so users can realize accrued
     *      LP trading-fee yield. This locks in plan §0 answer 5 + risk row 10.
     */
    function test_harvestLpFees_succeedsWhenSequencerDown() public {
        _deposit(portfolioFactory, portfolioAccount, DEPOSIT);

        // Generate honest yield (not adversarial inflation): pps grows 10%.
        ybLp.setPricePerShare(1.10e18);

        // Sequencer goes down AFTER the yield existed.
        _markDown();

        uint256 underlyingBefore = underlying.balanceOf(portfolioAccount);

        vm.prank(authorizedCaller);
        uint256 received = YieldBasisLpClaimingFacet(portfolioAccount).harvestLpFees(_floor85Local());

        assertGt(received, 0, "harvest must deliver yield even while sequencer is down");
        assertEq(
            underlying.balanceOf(portfolioAccount) - underlyingBefore,
            received,
            "balance delta matches return"
        );
    }

    // ─────────────────────────────────────────────────────────
    // G. Multi-config independence
    // ─────────────────────────────────────────────────────────

    function test_multiConfig_borrowOnGuardedRevertsButOptOutSucceeds() public {
        // Deposit into both factories.
        _deposit(portfolioFactory, portfolioAccount, DEPOSIT);
        _deposit(portfolioFactory2, portfolioAccount2, DEPOSIT);

        _markDown();

        // Guarded factory: borrow reverts.
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(YieldBasisLpLendingFacet.borrow.selector, 1e18);
        vm.expectRevert(SequencerLivenessLib.SequencerDown.selector);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();

        // Opt-out factory: borrow succeeds even though sequencer is "down" — its
        // config never points at the guard.
        assertEq(
            portfolioFactoryConfig2.getSequencerLivenessCheck(),
            address(0),
            "opt-out config must have no guard set"
        );
        _borrow(portfolioFactory2, 1e18);
        assertEq(ICollateralFacet(portfolioAccount2).getTotalDebt(), 1e18, "opt-out factory borrow succeeded");
    }
}
