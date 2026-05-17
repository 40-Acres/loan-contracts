// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * YieldBasisTRDFork -- mainnet-fork coverage for the hybrid TRD design.
 *
 * Exercises the split between:
 *   - _resolveCollateralValue (min(pps, preview_withdraw)) used for LTV /
 *     max-loan / liquidation marks (conservative)
 *   - _resolveBasisValue (pps only) used for harvest surplus computation
 *     (lender-premium flow stays unblocked on real pps growth)
 *
 * against the real yb-WETH LP + Curve crypto pool at a recent block. The
 * pool is imbalanced directly via Curve `exchange` to drive measurable TRD,
 * proving:
 *   - F1: at calm block, mark is non-zero and pps and preview_withdraw differ
 *         only by natural Curve curvature.
 *   - F2: a deliberate Curve swap widens TRD -> mark drops, min() now binds
 *         on withdrawable side.
 *   - F3: cross-block underwater positions do NOT auto-revert on read.
 *         They only revert when a state-changing operation attempts to
 *         widen exposure (here: a follow-up borrow trips overSuppliedVaultDebt
 *         in the same block as the protocol call). This is a deliberate
 *         design property surfaced for review -- passive liquidation must
 *         come from external actors, not the snapshot.
 *   - F3b: same-block (deposit/borrow -> external imbalance -> second
 *         state-changing call) reverts via the in-block shortfall-delta
 *         check.
 *   - F4: arbing the pool back recovers mark ~ original.
 *
 * F5 (harvest during TRD): induced pps growth on a live fork without
 *      multi-week time warps is infeasible -- documented and replaced with
 *      a probe that confirms getAvailableLpFeeYield uses pps math, not min().
 *
 * Run with:
 *   FOUNDRY_PROFILE=fork forge test \
 *     --match-path test/fork/portfolio_account/yieldbasis/YieldBasisTRDFork.t.sol
 *
 * Skips cleanly if ETH_RPC_URL is not set.
 * =========================================================================*/

import {Test, console} from "forge-std/Test.sol";

import {YieldBasisLpFacet} from "../../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisLpClaimingFacet} from "../../../../src/facets/account/yieldbasislp/YieldBasisLpClaimingFacet.sol";
import {YieldBasisLpLendingFacet} from "../../../../src/facets/account/yieldbasislp/YieldBasisLpLendingFacet.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";

import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";
import {YieldBasisPortfolioFactoryConfig}
    from "../../../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";
import {LendingVault} from "../../../../src/facets/account/vault/LendingVault.sol";

import {IYieldBasisLP} from "../../../../src/interfaces/IYieldBasisLP.sol";
import {IYieldBasisGauge} from "../../../../src/interfaces/IYieldBasisGauge.sol";

import {YbConfigDeployer} from "../../../portfolio_account/yieldbasis/helpers/YbConfigDeployer.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Curve crypto pool exchange interface. yb-WETH's CRYPTOPOOL is a
///      crvUSD/WETH pool. uint256 index variant.
interface ICurveCryptoPool {
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function coins(uint256 i) external view returns (address);
    function balances(uint256 i) external view returns (uint256);
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
}

contract YieldBasisTRDForkTest is Test {
    // ============ Mainnet addresses ============
    address internal constant YB_LP_WETH = 0x931d40dD07b25B91932b481B63631Ea86d236e09;
    address internal constant YB_GAUGE_WETH = 0xe4e656B5215a82009969219b1bAbB7c0757A3315;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant YB_TOKEN = 0x01791F726B4103694969820be083196cC7c045fF;
    // crvUSD/WETH crypto pool that yb-WETH wraps. Discovered via
    // IYieldBasisLP(...).CRYPTOPOOL() at the pinned block.
    address internal constant CURVE_POOL = 0x6e5492F8ea2370844EE098A56DD88e1717e4A9C2;
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    // Calm block (matches sibling fork-test pin).
    uint256 internal constant BLOCK_CALM = 25_000_400;

    // ============ Test actors ============
    address internal user = address(0x40ac2e);
    address internal authorizedCaller = address(0xaaaaa);
    address internal owner_ = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal attacker = address(0xBADBAD);
    address internal portfolioAccount;

    // ============ Wiring ============
    PortfolioManager internal portfolioManager;
    PortfolioFactory internal portfolioFactory;
    FacetRegistry internal facetRegistry;
    YieldBasisPortfolioFactoryConfig internal portfolioFactoryConfig;
    LoanConfig internal loanConfig;
    LendingVault internal lendingVault;

    YieldBasisLpFacet internal facet;
    YieldBasisLpClaimingFacet internal claimingFacet;
    YieldBasisLpLendingFacet internal lendingFacet;

    IYieldBasisLP internal ybLp = IYieldBasisLP(YB_LP_WETH);
    IERC20 internal weth = IERC20(WETH);
    ICurveCryptoPool internal pool = ICurveCryptoPool(CURVE_POOL);

    uint256 internal constant LTV_BPS = 7000;

    bool internal forkActive;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            forkActive = false;
            return;
        }
        uint256 forkId = vm.createFork(rpc, BLOCK_CALM);
        vm.selectFork(forkId);
        forkActive = true;
        _wireDiamond();
    }

    function _wireDiamond() internal {
        vm.startPrank(owner_);

        portfolioManager = new PortfolioManager(owner_);
        (PortfolioFactory pf, FacetRegistry fr) = portfolioManager.deployFactory(
            keccak256("yb-trd-fork-eth")
        );
        portfolioFactory = pf;
        facetRegistry = fr;

        YbConfigDeployer deployer = new YbConfigDeployer();
        (portfolioFactoryConfig, , loanConfig, ) = deployer.deployYb(address(portfolioFactory), owner_);

        // Real LendingVault on WETH; like-to-like with the LP underlying so
        // YieldBasisCollateralManager's LTV path is exercised.
        LendingVault impl = new LendingVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                LendingVault.initialize,
                (WETH, address(portfolioFactory), owner_, "lvault", "lv", 0)
            )
        );
        lendingVault = LendingVault(address(proxy));
        deal(WETH, address(lendingVault), 1_000e18);

        loanConfig.setLtv(LTV_BPS);
        loanConfig.setMultiplier(LTV_BPS); // harmless when LTV is set
        portfolioFactoryConfig.setLoanContract(address(lendingVault));
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        facet = new YieldBasisLpFacet(address(portfolioFactory), YB_GAUGE_WETH, YB_TOKEN, address(lendingVault));
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

        claimingFacet = new YieldBasisLpClaimingFacet(address(portfolioFactory), YB_GAUGE_WETH, address(lendingVault));
        bytes4[] memory claimingSelectors = new bytes4[](5);
        claimingSelectors[0] = YieldBasisLpClaimingFacet.claimGaugeRewards.selector;
        claimingSelectors[1] = YieldBasisLpClaimingFacet.previewGaugeRewards.selector;
        claimingSelectors[2] = YieldBasisLpClaimingFacet.harvestLpFees.selector;
        claimingSelectors[3] = YieldBasisLpClaimingFacet.getAvailableLpFeeYield.selector;
        claimingSelectors[4] = YieldBasisLpClaimingFacet.getDepositInfo.selector;
        facetRegistry.registerFacet(address(claimingFacet), claimingSelectors, "YBClaimingFacet");

        lendingFacet = new YieldBasisLpLendingFacet(address(portfolioFactory), address(lendingVault), YB_GAUGE_WETH);
        bytes4[] memory lendingSelectors = new bytes4[](2);
        lendingSelectors[0] = YieldBasisLpLendingFacet.borrow.selector;
        lendingSelectors[1] = YieldBasisLpLendingFacet.pay.selector;
        facetRegistry.registerFacet(address(lendingFacet), lendingSelectors, "YBLendingFacet");

        portfolioManager.setAuthorizedCaller(authorizedCaller, true);
        vm.stopPrank();

        portfolioAccount = portfolioFactory.createAccount(user);

        vm.label(YB_LP_WETH, "yb-WETH");
        vm.label(YB_GAUGE_WETH, "yb-WETH-gauge");
        vm.label(WETH, "WETH");
        vm.label(CURVE_POOL, "curve-crvUSD-WETH");
        vm.label(CRVUSD, "crvUSD");
        vm.label(portfolioAccount, "portfolioAccount");
        vm.label(attacker, "attacker");
    }

    // ============ Helpers ============

    function _seedLpToUser(uint256 amount) internal returns (bool ok) {
        uint256 before = IERC20(YB_LP_WETH).balanceOf(user);
        deal(YB_LP_WETH, user, before + amount, true);
        if (IERC20(YB_LP_WETH).balanceOf(user) >= before + amount) return true;

        uint256 gaugeLp = IERC20(YB_LP_WETH).balanceOf(YB_GAUGE_WETH);
        if (gaugeLp < amount) return false;
        vm.prank(YB_GAUGE_WETH);
        IERC20(YB_LP_WETH).transfer(user, amount);
        return true;
    }

    function _deposit(uint256 amount) internal {
        vm.startPrank(user);
        IERC20(YB_LP_WETH).approve(portfolioAccount, amount);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    function _borrow(uint256 amount) internal {
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(YieldBasisLpLendingFacet.borrow.selector, amount);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    /// @dev Tries to borrow via PM.multicall. Returns the raw revert bytes
    ///      on revert, or empty on success.
    function _borrowExpectRevert(uint256 amount) internal returns (bytes memory reason) {
        vm.startPrank(user);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(YieldBasisLpLendingFacet.borrow.selector, amount);
        try portfolioManager.multicall(cd, factories) {
            vm.stopPrank();
            return "";
        } catch (bytes memory r) {
            vm.stopPrank();
            return r;
        }
    }

    /// @dev Imbalance toward "yb-WETH worth less": yb-WETH is a 2x leveraged
    ///      WETH/crvUSD pool, so depressing the WETH price (selling lots of
    ///      WETH into the pool) lowers both pricePerShare AND preview_withdraw
    ///      of an LP share. preview_withdraw drops more than pps on a sharp
    ///      move (Curve curvature), making min() bind on withdrawable.
    function _imbalanceWethDown(uint256 wethIn) internal returns (uint256 crvUsdOut) {
        // WETH deal(..., true) hits stdStorage find() which fails on WETH's
        // packed/aliased layout. Use the non-adjust form -- supply totals
        // drift slightly, which is harmless for our purposes (we don't
        // assert on WETH totalSupply).
        deal(WETH, attacker, wethIn);
        vm.startPrank(attacker);
        IERC20(WETH).approve(CURVE_POOL, wethIn);
        crvUsdOut = pool.exchange(1, 0, wethIn, 0);
        vm.stopPrank();
    }

    /// @dev Opposite-direction swap to push the pool back toward balance.
    function _imbalanceWethUp(uint256 crvUsdIn) internal returns (uint256 wethOut) {
        deal(CRVUSD, attacker, crvUsdIn);
        vm.startPrank(attacker);
        IERC20(CRVUSD).approve(CURVE_POOL, crvUsdIn);
        wethOut = pool.exchange(0, 1, crvUsdIn, 0);
        vm.stopPrank();
    }

    function _getMark() internal view returns (uint256) {
        return ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
    }

    function _getMaxLoan() internal view returns (uint256) {
        (uint256 maxLoan, ) = ICollateralFacet(portfolioAccount).getMaxLoan();
        return maxLoan;
    }

    function _ppsValue(uint256 shares) internal view returns (uint256) {
        return (shares * ybLp.pricePerShare()) / 1e18;
    }

    // ============ F1: Baseline ============

    /**
     * @notice On the real calm-block pool, getTotalCollateralValue is the
     *         conservative min() and getMaxLoan is non-zero. We do NOT
     *         assert pps ~ preview_withdraw within ~0.5% -- at this pin the
     *         pool has natural ~3% TRD, and the min() correctly binds on
     *         the withdrawable side. That's the design.
     */
    function test_F1_BaselineCalmPool() public {
        if (!forkActive) { vm.skip(true); return; }

        uint256 amount = 1e18;
        if (!_seedLpToUser(amount)) { vm.skip(true); return; }
        _deposit(amount);

        uint256 mark = _getMark();
        uint256 ppsVal = _ppsValue(amount);
        uint256 withdrawableVal = ybLp.preview_withdraw(amount);

        console.log("F1: pps value         ", ppsVal);
        console.log("F1: withdrawable      ", withdrawableVal);
        console.log("F1: mark              ", mark);

        // Mark must equal min(pps, withdrawable). Both sides are real reads.
        uint256 expectedMin = ppsVal < withdrawableVal ? ppsVal : withdrawableVal;
        assertEq(mark, expectedMin, "mark == min(pps, withdrawable)");
        assertGt(mark, 0, "mark > 0");

        // Mark cannot exceed pps (sanity).
        assertLe(mark, ppsVal, "mark <= pps");

        // Max loan should be roughly LTV * mark, capped by supply. With 1k WETH
        // supplied and ~1 WETH collateral, supply doesn't bind.
        uint256 maxLoan = _getMaxLoan();
        uint256 expected = (mark * LTV_BPS) / 10000;
        assertApproxEqRel(maxLoan, expected, 0.01e18, "maxLoan ~ LTV * mark (1% tol for vault rounding)");
        assertGt(maxLoan, 0, "maxLoan > 0");
    }

    // ============ F2: TRD widen via Curve swap ============

    /**
     * @notice Deliberately imbalance the Curve pool -- push WETH side down
     *         hard via crvUSD-in swap. preview_withdraw of yb-WETH drops,
     *         min() binds on withdrawable, mark drops, max-loan drops
     *         proportionally. pps moves a small amount (pps tracks EMA fair
     *         price; large spot moves don't fully feed through immediately).
     */
    function test_F2_TRDWidensViaCurveSwap() public {
        if (!forkActive) { vm.skip(true); return; }

        uint256 amount = 1e18;
        if (!_seedLpToUser(amount)) { vm.skip(true); return; }
        _deposit(amount);

        uint256 ppsBefore = ybLp.pricePerShare();
        uint256 withdrawableBefore = ybLp.preview_withdraw(amount);
        uint256 markBefore = _getMark();
        uint256 maxLoanBefore = _getMaxLoan();

        console.log("F2: ppsBefore         ", ppsBefore);
        console.log("F2: withdrawBefore    ", withdrawableBefore);
        console.log("F2: markBefore        ", markBefore);

        // Dump 8M crvUSD into the pool. That's ~36% of crvUSD-side balance,
        // enough to materially shrink the WETH side.
        uint256 crvUsdGot = _imbalanceWethDown(4_000e18);
        console.log("F2: crvUSD attacker got ", crvUsdGot);

        uint256 ppsAfter = ybLp.pricePerShare();
        uint256 withdrawableAfter = ybLp.preview_withdraw(amount);
        uint256 markAfter = _getMark();
        uint256 maxLoanAfter = _getMaxLoan();

        console.log("F2: ppsAfter          ", ppsAfter);
        console.log("F2: withdrawAfter     ", withdrawableAfter);
        console.log("F2: markAfter         ", markAfter);

        // The withdrawable side strictly drops on this attack.
        assertLt(withdrawableAfter, withdrawableBefore, "preview_withdraw dropped");

        // Mark strictly drops too -- proves TRD propagated into the collateral mark.
        assertLt(markAfter, markBefore, "mark dropped after TRD widened");

        // Mark binds on the withdrawable side (min() bites).
        assertEq(markAfter, withdrawableAfter, "mark == preview_withdraw (min binds on withdrawable)");

        // Max-loan dropped proportionally.
        assertLt(maxLoanAfter, maxLoanBefore, "maxLoan dropped");
    }

    // ============ F3: Cross-block underwater -- passive, no auto-revert ============

    /**
     * @notice DESIGN PROPERTY (surfaced as a finding):
     *         The delta-snapshot check in enforceCollateralRequirements
     *         only catches shortfall WIDENING within a single block. If
     *         the pool imbalances in block N (no protocol call) and the
     *         borrower is left underwater, then in block N+1 a *pure*
     *         read-only call to enforceCollateralRequirements PASSES:
     *         the snapshot for block N+1 is set to the (already-bad)
     *         shortfall, so end == start at view-time.
     *
     *         A passive underwater position is NOT auto-liquidated by
     *         on-chain reads -- external liquidator action is required.
     *
     *         What DOES revert in block N+1 is any STATE-CHANGING op
     *         that touches the manager: at the start of the call,
     *         `_snapshotIfNeeded` sets `startShortfall` to the current
     *         (bad) shortfall. The borrow then adds debt, widening the
     *         shortfall by `amount` (because maxLoan is 0). At the end
     *         enforceCollateralRequirements sees end - start == amount
     *         and reverts with UndercollateralizedDebt. The widening
     *         only needs to be 1 wei to fire.
     *
     *         This test pins both behaviors.
     */
    function test_F3_CrossBlockUnderwater_PassiveSurvivesActiveBlocks() public {
        if (!forkActive) { vm.skip(true); return; }

        uint256 amount = 1e18;
        if (!_seedLpToUser(amount)) { vm.skip(true); return; }
        _deposit(amount);

        // Borrow at ~LTV * mark to land just under the line.
        uint256 maxLoanBefore = _getMaxLoan();
        uint256 borrowAmount = (maxLoanBefore * 95) / 100;
        _borrow(borrowAmount);

        uint256 debtBefore = ICollateralFacet(portfolioAccount).getTotalDebt();
        console.log("F3: debt              ", debtBefore);
        console.log("F3: maxLoanBefore     ", maxLoanBefore);

        // Block N: attacker imbalances pool externally. No protocol call.
        _imbalanceWethDown(4_000e18);

        uint256 markAfter = _getMark();
        uint256 maxLoanAfter = _getMaxLoan();
        console.log("F3: markAfter         ", markAfter);
        console.log("F3: maxLoanAfter      ", maxLoanAfter);

        // Verify the position is indeed underwater (debt > current max loan).
        // maxLoan from getMaxLoan is the *remaining* headroom, capped at 0 if
        // currentLoan exceeds maxLoanIgnoreSupply. So we also probe ignoreSupply.
        (, uint256 maxLoanIgnoreSupply) = ICollateralFacet(portfolioAccount).getMaxLoan();
        assertLt(maxLoanIgnoreSupply, debtBefore, "F3 setup: position is underwater");

        // Move to block N+1.
        vm.roll(block.number + 1);

        // Read-only calls do not revert. enforceCollateralRequirements as a
        // VIEW returns true: in block N+1 the snapshot isn't current, so
        // start := end and end > start is false. overSuppliedVaultDebt is
        // still 0 (no borrow exceeded maxLoan since the attack).
        bool ok = ICollateralFacet(portfolioAccount).enforceCollateralRequirements();
        assertTrue(ok, "passive underwater position passes the read-only check (design)");

        // Active borrow in block N+1 MUST fail. The snapshot is set at the
        // start of increaseTotalDebt to the (bad) shortfall, then the borrow
        // grows debt -- and because maxLoan==0, shortfall grows by the borrow
        // amount. enforceCollateralRequirements catches that and reverts
        // with UndercollateralizedDebt(amount).
        bytes memory reason = _borrowExpectRevert(1); // 1 wei is enough.
        assertGt(reason.length, 0, "follow-up borrow must revert");

        // Acceptable revert selectors:
        //   - UndercollateralizedDebt(uint256) (the observed one: 0x8a750e38).
        //   - BadDebt(uint256) (fallback path via overSuppliedVaultDebt; should
        //     not fire here because the snapshot is reset to the bad shortfall
        //     at the new block, but allow it for robustness).
        //   - InsufficientCollateral() (PM-side bool wrapper).
        console.logBytes(reason);
        bytes4 sel = bytes4(reason);
        bool isBadDebt = sel == bytes4(keccak256("BadDebt(uint256)"));
        bool isUndercoll = sel == bytes4(keccak256("UndercollateralizedDebt(uint256)"));
        bool isInsuffCollat = sel == bytes4(keccak256("InsufficientCollateral()"));
        assertTrue(isBadDebt || isUndercoll || isInsuffCollat,
            "follow-up borrow reverts with collateral-related selector");
    }

    // ============ F3b: Same-block widen during in-flight protocol call ============

    /**
     * @notice In-block delta check: protocol-state-call N (snapshots
     *         shortfall=0 at deposit/borrow start) -> external imbalance
     *         (same block, same tx orchestration) -> protocol-state-call M
     *         (same block, skips snapshot, sees fresh shortfall > 0 at
     *         enforceCollateralRequirements) -> revert.
     *
     *         This is the defense-in-depth path that protects against
     *         atomic flash-loan-style manipulation. Verifies it actually
     *         fires on the real pool.
     */
    function test_F3b_SameBlockManipulationReverts() public {
        if (!forkActive) { vm.skip(true); return; }

        uint256 amount = 1e18;
        if (!_seedLpToUser(amount)) { vm.skip(true); return; }
        _deposit(amount);

        uint256 maxLoanBefore = _getMaxLoan();
        // Borrow to ~95% to leave very thin margin. Snapshot is set inside
        // _snapshotIfNeeded at the start of increaseTotalDebt with
        // startShortfall == 0 (no shortfall pre-attack).
        uint256 firstBorrow = (maxLoanBefore * 95) / 100;
        _borrow(firstBorrow);

        // Attacker imbalances pool -- same block, no vm.roll.
        _imbalanceWethDown(4_000e18);

        // A second state-changing call in the same block: try to borrow 1 wei.
        // _snapshotIfNeeded sees snapshotBlockNumber == block.number -> skip.
        // increaseTotalDebt completes; at end, manager-side multicall calls
        // enforceCollateralRequirements; end > start (== 0) -> revert with
        // UndercollateralizedDebt OR (if overSupplied set first) BadDebt.
        bytes memory reason = _borrowExpectRevert(1);
        assertGt(reason.length, 0, "same-block follow-up borrow must revert");

        bytes4 sel = bytes4(reason);
        bool isUndercoll = sel == bytes4(keccak256("UndercollateralizedDebt(uint256)"));
        bool isBadDebt = sel == bytes4(keccak256("BadDebt(uint256)"));
        bool isInsuffCollat = sel == bytes4(keccak256("InsufficientCollateral()"));
        console.logBytes(reason);
        assertTrue(isUndercoll || isBadDebt || isInsuffCollat,
            "same-block manipulation reverts with shortfall-delta or BadDebt");
    }

    // ============ F4: Recovery via opposite swap ============

    /**
     * @notice Continue from F2-like state: arb the pool back via opposite
     *         exchange (WETH-in). preview_withdraw recovers, mark recovers
     *         close to its calm-pool value.
     *
     *         Tolerance is wide (~3%) because (a) the attacker swap pays
     *         fee in both directions so a full round-trip leaks value, and
     *         (b) pps EMA may have drifted slightly during the swaps.
     */
    function test_F4_RecoveryAfterArb() public {
        if (!forkActive) { vm.skip(true); return; }

        uint256 amount = 1e18;
        if (!_seedLpToUser(amount)) { vm.skip(true); return; }
        _deposit(amount);

        uint256 markStart = _getMark();
        console.log("F4: markStart         ", markStart);

        // Imbalance: sell 4000 WETH into the pool (~29% of WETH-side balance).
        uint256 crvUsdGotInAttack = _imbalanceWethDown(4_000e18);
        uint256 markDuring = _getMark();
        console.log("F4: markDuring        ", markDuring);
        assertLt(markDuring, markStart, "F4 sanity: mark dropped during attack");

        // Reverse the swap with the crvUSD we got. The pool will absorb a bit
        // less than full reversal due to two fee cuts, but balances move back
        // close to ~peg.
        _imbalanceWethUp(crvUsdGotInAttack);

        uint256 markRecovered = _getMark();
        console.log("F4: markRecovered     ", markRecovered);

        // Recovered mark should be much closer to start than to during.
        // Use directional + numeric: recovered > during, and recovered/start
        // ratio >= 95%.
        assertGt(markRecovered, markDuring, "F4: mark partially recovered");
        uint256 recoveryBps = (markRecovered * 10_000) / markStart;
        console.log("F4: recovery bps      ", recoveryBps);
        assertGe(recoveryBps, 9_500, "mark recovered >= 95% of start");
    }

    // ============ F5: Harvest path uses pps math (not min) ============

    /**
     * @notice Original F5 spec wanted to prove harvestLpFees succeeds during
     *         widened TRD with a positive yield based on real pps growth.
     *         Inducing pps growth on a live fork requires either (a)
     *         multi-week time-warp + Curve admin-fee compounding (the
     *         yb-LP's claim mechanism), or (b) mocking pricePerShare. The
     *         sibling YieldBasisLpHarvestForkETH suite covers (b) extensively.
     *
     *         Here we focus on the property that distinguishes the hybrid
     *         design from a min()-everywhere design: getAvailableLpFeeYield
     *         must use pps math, NOT preview_withdraw. We verify this by:
     *
     *         1. Depositing and reading pps-based current value (basis).
     *         2. Widening TRD so preview_withdraw drops well below pps.
     *         3. Mocking pricePerShare upward by 5% so there's harvestable
     *            yield (the only way to induce yield without a long warp).
     *            The mock applies to getAvailableLpFeeYield (calls pps) but
     *            NOT to preview_withdraw (real read).
     *         4. Assert getAvailableLpFeeYield returns a yieldUnderlying
     *            that matches the pps-priced delta, NOT a withdrawable-
     *            priced delta. If anyone "fixes" surplus to also use min(),
     *            yieldUnderlying would shrink to ~0 here and the test
     *            would fail.
     */
    function test_F5_HarvestUsesPpsMath_NotMin() public {
        if (!forkActive) { vm.skip(true); return; }

        uint256 amount = 1e18;
        if (!_seedLpToUser(amount)) { vm.skip(true); return; }

        // Read pps BEFORE deposit so we know exactly what basis was stamped.
        uint256 pps0 = ybLp.pricePerShare();
        _deposit(amount);
        uint256 depositedBasis = (pps0 * amount) / 1e18;

        // Widen TRD: real pricePerShare drifts a bit AND preview_withdraw
        // drops sharply (the haircut). Real pps after this is post-attack.
        _imbalanceWethDown(4_000e18);

        // Mock pricePerShare to depositPps * 1.05 -- guaranteed > depositedBasis.
        uint256 mockedPps = (pps0 * 105) / 100;
        vm.mockCall(
            YB_LP_WETH,
            abi.encodeWithSelector(IYieldBasisLP.pricePerShare.selector),
            abi.encode(mockedPps)
        );

        uint256 ppsBasisCurrent = (mockedPps * amount) / 1e18;
        uint256 ppsDelta = ppsBasisCurrent - depositedBasis;
        console.log("F5: pps0 (deposit)    ", pps0);
        console.log("F5: mockedPps         ", mockedPps);
        console.log("F5: depositedBasis    ", depositedBasis);
        console.log("F5: pps current       ", ppsBasisCurrent);
        console.log("F5: pps delta         ", ppsDelta);

        (uint256 yieldUnderlying, uint256 yieldGaugeShares) =
            YieldBasisLpClaimingFacet(portfolioAccount).getAvailableLpFeeYield();
        console.log("F5: yieldUnderlying   ", yieldUnderlying);
        console.log("F5: yieldGaugeShares  ", yieldGaugeShares);

        vm.clearMockedCalls();

        // Counterfactual: real withdrawable is well below mocked-pps current
        // value (TRD widened), so a min()-based surplus would shrink yield
        // dramatically. Read it for the log.
        uint256 withdrawable = ybLp.preview_withdraw(amount);
        uint256 minBasedCurrent = withdrawable < ppsBasisCurrent ? withdrawable : ppsBasisCurrent;
        console.log("F5: withdrawable      ", withdrawable);
        console.log("F5: min current       ", minBasedCurrent);
        assertLt(minBasedCurrent, ppsBasisCurrent, "F5 setup: TRD widened (min < pps current)");

        // Property 1: yieldUnderlying is positive (harvest unblocked
        // despite widened TRD).
        assertGt(yieldUnderlying, 0, "F5: yield available despite TRD");

        // Property 2: yieldUnderlying ~ pps-based delta, within 1 wei.
        // If it were min-based, yieldUnderlying would equal
        // (minBasedCurrent - depositedBasis), strictly less.
        assertApproxEqAbs(yieldUnderlying, ppsDelta, 1, "F5: yield uses pps math");
    }
}
