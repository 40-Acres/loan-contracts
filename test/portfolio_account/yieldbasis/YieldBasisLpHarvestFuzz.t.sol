// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/* ===========================================================================
 * YieldBasisLpHarvestFuzz — property-based coverage for harvestLpFees
 * ===========================================================================
 *
 * Mirrors the setUp / helpers from YieldBasisLpHarvestHardSplit.t.sol, then
 * runs a randomized harness over the harvest pipeline.
 *
 * Properties verified per run (when harvest succeeds):
 *   P1 — slippage cap: delivered >= (lpToBurn * minPerShare) / 1e18.
 *        Enforced inside _lpToken.withdraw via min_assets; we re-check
 *        externally as a defense-in-depth.
 *   P2 — basis preserved: post-harvest sharesPost*pps + tolerance >= depPost,
 *        i.e. per-share basis D'/S' is preserved (S'*p >= D').
 *   P3 — no over-tracking: sharesPost <= directLpPost +
 *        gauge.convertToAssets(gaugeBalPost) within rounding. Tracked LP must
 *        never exceed actually-recoverable LP.
 *   P4 — value conservation: delivered + sharesPost*pps ~= sharesPre*pps
 *        within rounding (this is a tighter form of P2 that catches surplus
 *        being computed against the wrong base).
 *
 * If priceGrowthBps == 0 AND skimBps == 0, harvest correctly reverts
 * "No yield to harvest"; we accept that and skip property checks.
 * =========================================================================*/

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {YieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpFacet.sol";
import {YieldBasisLpClaimingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpClaimingFacet.sol";
import {YieldBasisLpLendingFacet} from "../../../src/facets/account/yieldbasislp/YieldBasisLpLendingFacet.sol";
import {YieldBasisCollateralManager} from "../../../src/facets/account/yieldbasislp/YieldBasisCollateralManager.sol";
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
import {HarvestFloor85} from "./helpers/HarvestFloor85.sol";
import {IYieldBasisLP} from "../../../src/interfaces/IYieldBasisLP.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract YieldBasisLpHarvestFuzzTest is Test, HarvestFloor85 {
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

    address internal user = address(0x40ac2e);
    address internal authorizedCaller = address(0xaaaaa);
    address internal owner_ = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address internal portfolioAccount;

    uint256 internal constant VAULT_LIQ = 10_000_000e18;
    uint256 internal constant LTV_BPS = 7000;

    function setUp() public {
        vm.startPrank(owner_);

        portfolioManager = new PortfolioManager(owner_);
        (PortfolioFactory pf, FacetRegistry fr) = portfolioManager.deployFactory(
            keccak256("harvest-fuzz")
        );
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

        vm.stopPrank();

        portfolioAccount = portfolioFactory.createAccount(user);

        // Seed user with plenty of LP and the LP mock with plenty of underlying
        // so that high-bound fuzz cases never run dry.
        ybLp.mint(user, 1e26);                    // 100M LP
        underlying.mint(address(ybLp), 1e30);     // 1e12 underlying — easily covers any harvest

        vm.label(address(ybLp), "ybLp");
        vm.label(address(gauge), "gauge");
        vm.label(address(underlying), "underlying");
        vm.label(portfolioAccount, "portfolioAccount");
    }

    // ============ Helpers (mirrored from unit suite) ============

    function _deposit(uint256 amount) internal {
        vm.startPrank(user);
        ybLp.approve(portfolioAccount, amount);
        bytes[] memory cd = new bytes[](1);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        cd[0] = abi.encodeWithSelector(YieldBasisLpFacet.deposit.selector, amount);
        portfolioManager.multicall(cd, factories);
        vm.stopPrank();
    }

    function _depositAndStake(uint256 amount) internal {
        _deposit(amount);
        vm.prank(owner_);
        portfolioFactoryConfig.setStakedGaugeMode(true);
        vm.prank(authorizedCaller);
        YieldBasisLpFacet(portfolioAccount).setStakedMode();
        // Reset directive so subsequent _deposit calls don't auto-stake.
        vm.prank(owner_);
        portfolioFactoryConfig.setStakedGaugeMode(false);
    }

    function _floor85() internal view returns (uint256) {
        return _floor85(IYieldBasisLP(address(ybLp)));
    }

    // ============ Fuzz Harness ============

    /**
     * @notice Property-based test of harvestLpFees over randomized inputs.
     *
     * Bounded inputs:
     *   - totalLp:           1 LP – 10,000 LP (1e18 wei units)
     *   - stakedPctBps:      0 – 100% of totalLp staked in gauge
     *   - skimBps:           0 – 5% gauge skim (drift down on staked LP)
     *   - priceGrowthBps:    0 – 50% pps growth above 1.0
     *   - withdrawHaircutBps: 0 – 15% LP burn-side haircut (within 85% floor)
     *
     * Verifies the four numeric properties listed at file top, plus that no
     * arithmetic underflow / unexpected revert occurs on legitimate inputs.
     */
    function testFuzz_HarvestProperties(
        uint256 totalLp,
        uint256 stakedPctBpsRaw,
        uint256 skimBpsRaw,
        uint256 priceGrowthBpsRaw,
        uint256 withdrawHaircutBpsRaw
    ) public {
        totalLp = bound(totalLp, 1e18, 1e22);                                          // 1 – 10,000 LP
        uint256 stakedPctBps = bound(stakedPctBpsRaw, 0, 10_000);
        uint256 skimBps = bound(skimBpsRaw, 0, 500);                                   // 0 – 5%
        uint256 priceGrowthBps = bound(priceGrowthBpsRaw, 0, 5000);                    // 0 – 50%
        uint256 withdrawHaircutBps = bound(withdrawHaircutBpsRaw, 0, 1500);            // 0 – 15%

        // 1. Stage staked / unstaked split. We must avoid the "stake everything"
        //    side-effect of setStakedMode: deposit the staked portion first and
        //    flip to staked mode (stakes whatever's there), then deposit the
        //    unstaked portion which will *not* auto-stake unless the factory
        //    flag is on (it isn't in our setUp).
        uint256 stakedLp = (totalLp * stakedPctBps) / 10_000;
        uint256 unstakedLp = totalLp - stakedLp;

        if (stakedLp > 0) {
            _depositAndStake(stakedLp);
        }
        if (unstakedLp > 0) {
            _deposit(unstakedLp);
        }

        // 2. Apply gauge skim (only meaningful if there's staked LP).
        //    convertRatioBps = 10_000 - skimBps so the staked LP "loses" skimBps
        //    of its value in convertToAssets.
        if (stakedLp > 0 && skimBps > 0) {
            gauge.setConvertRatioBps(10_000 - skimBps);
        }

        // 3. Bump pps and apply LP-side withdraw haircut.
        uint256 newPps = (1e18 * (10_000 + priceGrowthBps)) / 10_000;
        ybLp.setPricePerShare(newPps);
        if (withdrawHaircutBps > 0) {
            ybLp.setWithdrawHaircutBps(withdrawHaircutBps);
        }

        // 4. Compute caller's minPerShare.
        //    Target: pps × (1 - haircut - 1% extra slack), bounded below by the
        //    85% floor. Any value below 85% would revert pre-flight ("Slippage
        //    floor < 85%") which we don't want; values above the LP's actual
        //    delivered rate would revert at the LP layer ("min_assets").
        uint256 minPerShare;
        {
            uint256 slackBps = uint256(withdrawHaircutBps) + 100; // give 1% extra
            if (slackBps > 1500) slackBps = 1500; // cap at 15% so we never go below 85%
            minPerShare = (newPps * (10_000 - slackBps)) / 10_000;
            uint256 floor85 = _floor85();
            if (minPerShare < floor85) minPerShare = floor85;
        }

        // 5. Capture pre-state.
        (uint256 sharesPre, , ) =
            YieldBasisLpClaimingFacet(portfolioAccount).getDepositInfo();
        uint256 directLpPre = ybLp.balanceOf(portfolioAccount);
        uint256 gaugeBalPre = gauge.balanceOf(portfolioAccount);
        uint256 actualLpPre = directLpPre + gauge.convertToAssets(gaugeBalPre);
        uint256 underlyingPre = underlying.balanceOf(portfolioAccount);

        // NB: pre-skim sharesPre may exceed actualLpPre (gauge skim eroded the
        // gauge value below tracked). reconcile inside harvest collapses the
        // delta — that's the contract's job, not the test's. We don't assert
        // anything pre-harvest about that relationship.

        // 6. Compute whether harvest should produce yield. After reconcile,
        //    tracked shares collapse down to actualLpPre (if smaller). Then
        //    yield exists iff actualLpPre * pps > depositedAssetValue * (actualLpPre/sharesPre).
        //    Simpler: post-reconcile currentValue > postReconcileDepositedValue
        //    iff pps > 1 (since deposit happened at pps=1, post-reconcile basis
        //    is preserved per-share). With priceGrowthBps == 0, the only way to
        //    have yield is... none — reconcile is one-way down, doesn't extract
        //    skim as yield. So if priceGrowthBps == 0, expect "No yield".
        bool expectNoYield = (priceGrowthBps == 0);

        // 7. Harvest.
        vm.recordLogs();
        if (expectNoYield) {
            vm.startPrank(authorizedCaller);
            vm.expectRevert(bytes("No yield to harvest"));
            YieldBasisLpClaimingFacet(portfolioAccount).harvestLpFees(minPerShare);
            vm.stopPrank();
            return; // no properties to check on a legitimate revert
        }

        vm.startPrank(authorizedCaller);
        try YieldBasisLpClaimingFacet(portfolioAccount).harvestLpFees(minPerShare) returns (uint256 received) {
            vm.stopPrank();

            // 8. Capture post-state and locate the LpFeesHarvested event.
            (uint256 sharesPost, uint256 depPost, ) =
                YieldBasisLpClaimingFacet(portfolioAccount).getDepositInfo();
            uint256 directLpPost = ybLp.balanceOf(portfolioAccount);
            uint256 gaugeBalPost = gauge.balanceOf(portfolioAccount);
            uint256 actualLpPost = directLpPost + gauge.convertToAssets(gaugeBalPost);
            uint256 underlyingPost = underlying.balanceOf(portfolioAccount);

            // Parse event to get lpToBurn for P1.
            uint256 lpToBurn = _readLpToBurnFromLogs();

            // P1: slippage cap honored.
            uint256 minOut = (lpToBurn * minPerShare) / 1e18;
            assertGe(received, minOut, "P1: delivered >= lpToBurn * minPerShare / 1e18");

            // Underlying balance delta matches `received` return.
            assertEq(underlyingPost - underlyingPre, received, "underlying delta == received");

            // P2: per-share basis preserved (S'*p >= D' within tolerance).
            uint256 sharesPostValue = (sharesPost * newPps) / 1e18;
            assertGe(sharesPostValue + 2, depPost, "P2: S'*p >= D' (basis preserved)");

            // P3: tracked shares <= recoverable LP within rounding.
            assertLe(sharesPost, actualLpPost + 2, "P3: tracked <= recoverable + tolerance");

            // P4: value conservation.
            //   sharesPre*pps is the post-reconcile value (after collapsing tracked
            //   to actualLpPre); but only if sharesPre <= actualLpPre. If sharesPre
            //   was larger, reconcile dropped it to actualLpPre. We use the
            //   smaller of the two as the post-reconcile starting value.
            uint256 effectiveSharesPre = sharesPre > actualLpPre ? actualLpPre : sharesPre;
            uint256 valuePre = (effectiveSharesPre * newPps) / 1e18;

            // Loose tolerance: 4 wei + the LP-side haircut bps slop. The Curve
            // haircut converts fair → delivered, so received < (lpToBurn * pps),
            // which means valuePre - received - sharesPostValue == haircut shortfall.
            // We account for that via a haircut-proportional slack.
            uint256 haircutSlack = (valuePre * uint256(withdrawHaircutBps)) / 10_000 + 4;

            // received + (sharesPost * pps) ~= sharesPre * pps  (within haircut slack)
            assertApproxEqAbs(
                received + sharesPostValue,
                valuePre,
                haircutSlack,
                "P4: value conservation (delivered + remaining ~= initial)"
            );
        } catch (bytes memory reason) {
            vm.stopPrank();
            // Some fuzz combos legitimately revert: e.g. removeSharesForYield's
            // "Yield too small to harvest" guard at extremely tiny surplus, or
            // the LP-side min_assets check if our min computation undershoots
            // due to integer truncation. We allow these but do NOT allow
            // anything else (e.g. arithmetic panics).
            if (_isAcceptableRevert(reason)) {
                return;
            }
            // Re-bubble unexpected reverts so failures surface clearly.
            assembly {
                let len := mload(reason)
                revert(add(reason, 0x20), len)
            }
        }
    }

    /// @dev Pulls the `lpTokensBurned` field from the most recent
    ///      LpFeesHarvested event. Reverts if no matching event found.
    function _readLpToBurnFromLogs() internal returns (uint256 lpToBurn) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("LpFeesHarvested(uint256,uint256,uint256,address)");
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory log = logs[i - 1];
            if (log.emitter == portfolioAccount && log.topics.length > 0 && log.topics[0] == sig) {
                ( , uint256 _lpToBurn, ) = abi.decode(log.data, (uint256, uint256, uint256));
                return _lpToBurn;
            }
        }
        revert("LpFeesHarvested event not found");
    }

    /// @dev Whitelist of revert reasons we accept as "legitimate fuzz boundary"
    ///      reverts that should not fail the property test.
    function _isAcceptableRevert(bytes memory reason) internal pure returns (bool) {
        if (reason.length < 4) return false;
        // Custom selectors (none expected here for harvest path under fuzz, but
        // keep door open for future).
        // Pattern-match string reverts (Error(string)).
        bytes4 selector;
        assembly { selector := mload(add(reason, 32)) }
        if (selector != 0x08c379a0) return false; // Error(string)

        // Decode the string payload.
        bytes memory body = new bytes(reason.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = reason[i + 4];
        }
        string memory msgStr = abi.decode(body, (string));
        bytes32 h = keccak256(bytes(msgStr));

        // Acceptable harvest-path reverts under fuzz:
        //   - "No yield to harvest"        : reconcile collapsed all yield (skim ≥ growth)
        //   - "Yield too small to harvest" : surplusShares == 0 from integer truncation
        //   - "min_assets"                 : LP delivered less than our minOut due to rounding
        //   - "Debt exceeds max loan"      : reconcile shrunk basis below LTV (no debt here, unlikely)
        if (h == keccak256(bytes("No yield to harvest"))) return true;
        if (h == keccak256(bytes("Yield too small to harvest"))) return true;
        if (h == keccak256(bytes("min_assets"))) return true;
        if (h == keccak256(bytes("Debt exceeds max loan"))) return true;
        return false;
    }
}
