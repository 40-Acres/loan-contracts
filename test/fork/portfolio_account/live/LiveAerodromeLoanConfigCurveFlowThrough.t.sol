// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {LiveDeploymentSetup} from "./LiveDeploymentSetup.sol";
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../../src/facets/account/lending/BaseLendingFacet.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {RewardsProcessingFacet} from "../../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";
import {Loan as LoanV2} from "../../../../src/LoanV2.sol";
import {SwapMod} from "../../../../src/facets/account/swap/SwapMod.sol";
import {VotingFacet} from "../../../../src/facets/account/vote/VotingFacet.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {ClaimingFacet} from "../../../../src/facets/account/claim/ClaimingFacet.sol";
import {IVoter} from "../../../../src/interfaces/IVoter.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @title LiveAerodromeLoanConfigCurveFlowThrough
 * @dev Integration fork test on live Base data proving the two-slope lender
 *      premium curve flows END-TO-END through processRewards consumption.
 *
 *      The curve source is the REAL prod LoanConfig proxy, upgraded to the
 *      current branch impl and rewired into the freshly deployed account stack.
 *      The above-kink and cap-binding LTV bands are reached with a REAL
 *      underwater state by lowering rewardsRate/multiplier as the config owner
 *      after borrowing (no vm.mockCall on getLoanUtilization).
 *
 *      Run:
 *      FOUNDRY_PROFILE=fork forge test \
 *        --match-path test/fork/portfolio_account/live/LiveAerodromeLoanConfigCurveFlowThrough.t.sol -vv
 */
contract LiveAerodromeLoanConfigCurveFlowThrough is LiveDeploymentSetup {
    // Real prod LoanConfig proxy + its owning safe on Base.
    address public constant PROD_LOAN_CONFIG = 0xa5b8bC2C39c669132930AdFD3e56E988e5629C88;
    address public constant PROD_OWNER_SAFE = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;

    // Prod curve params: base, slope, kink, cap, slopeBelow.
    uint256 internal constant CURVE_BASE = 1500;
    uint256 internal constant CURVE_SLOPE = 1500;
    uint256 internal constant CURVE_KINK = 15000;
    uint256 internal constant CURVE_CAP = 4500;
    uint256 internal constant CURVE_SLOPE_BELOW = 500;

    // Prod treasury fee is 500 bps; cash-flow market params for the fresh stack.
    uint256 internal constant TREASURY_FEE = 500;
    uint256 internal constant REWARDS_RATE = 2850;
    uint256 internal constant MULTIPLIER = 52;
    uint256 internal constant LTV = 7000;

    // Round amount so floor division is exact -> assertEq.
    uint256 internal constant REWARDS_AMOUNT = 1_000_000e6;

    // Literal epoch width; do not recompute boundaries on block.timestamp across warps.
    uint256 internal constant WEEK = 7 days;

    // Known Aerodrome pools with alive gauges (fallbacks for the votable-pool resolver).
    address internal constant USDC_AERO_POOL = 0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d;
    address internal constant WETH_USDC_POOL = 0xcDAC0d6c6C59727a65F871236188350531885C43;

    LoanConfig internal prodConfig;

    // keccak of the LenderPremiumPaid event signature.
    bytes32 internal constant LENDER_PREMIUM_PAID_TOPIC =
        keccak256("LenderPremiumPaid(uint256,uint256,uint256,address,address)");

    function setUp() public override {
        super.setUp();

        prodConfig = LoanConfig(PROD_LOAN_CONFIG);

        // 1. Upgrade the prod proxy to the current-branch impl and set the prod
        //    curve atomically. The live impl predates the curve, so this upgrade
        //    is what gives the proxy setLenderPremiumCurve/getLenderPremium.
        LoanConfig newImpl = new LoanConfig();
        bytes memory data = abi.encodeCall(
            LoanConfig.setLenderPremiumCurve,
            (CURVE_BASE, CURVE_SLOPE, CURVE_KINK, CURVE_CAP, CURVE_SLOPE_BELOW)
        );
        vm.prank(PROD_OWNER_SAFE);
        UUPSUpgradeable(PROD_LOAN_CONFIG).upgradeToAndCall(address(newImpl), data);

        // 2. The prod proxy may have rate/multiplier/ltv unset; set sensible
        //    values so the cash-flow market works. First-set-from-zero skips the
        //    "<= 2x current" guard; later lowering is always allowed.
        vm.startPrank(PROD_OWNER_SAFE);
        prodConfig.setRewardsRate(REWARDS_RATE);
        prodConfig.setMultiplier(MULTIPLIER);
        prodConfig.setLtv(LTV);
        vm.stopPrank();
        assertEq(prodConfig.getTreasuryFee(), TREASURY_FEE, "prod treasuryFee should be 500");

        // 3. Rewire the account's config to read the prod proxy curve. Only the
        //    loanConfig is repointed; the loan contract (vault) is unchanged.
        address loanContractBefore = portfolioFactoryConfig.getLoanContract();
        vm.prank(liveOwner);
        portfolioFactoryConfig.setLoanConfig(PROD_LOAN_CONFIG);
        assertEq(address(portfolioFactoryConfig.getLoanConfig()), PROD_LOAN_CONFIG, "loanConfig rewired to prod");
        assertEq(portfolioFactoryConfig.getLoanContract(), loanContractBefore, "loanContract must be unchanged");
        assertEq(loanContractBefore, loanContract, "loanContract should be the fresh vault loan");

        // 4. Authorize this test as a processor (processRewards is onlyAuthorizedCaller).
        vm.prank(liveOwner);
        portfolioManager.setAuthorizedCaller(address(this), true);
        assertTrue(portfolioManager.isAuthorizedCaller(address(this)), "test must be authorized caller");

        // Curve sanity: the prod getter agrees with the hand-computed bands.
        assertEq(prodConfig.getLenderPremium(8000), 1900, "below-kink rate at 8000 bps should be 1900");
        assertEq(prodConfig.getLenderPremium(20000), 3000, "above-kink rate at 20000 bps should be 3000");
        assertEq(prodConfig.getLenderPremium(30000), 4500, "cap rate at 30000 bps should be 4500");
    }

    // --- Helpers --------------------------------------------------------

    function _healthLtv() internal view returns (uint256) {
        // Read through the account so the library hits the account's storage,
        // not the test contract's.
        return ICollateralFacet(portfolioAccount).getLoanUtilization();
    }

    /// @dev Add the setUp veNFT as collateral and borrow `targetFraction`/10000 of maxLoan.
    function _addCollateralAndBorrow(uint256 targetFractionBps) internal returns (uint256 borrowed) {
        _addCollateral(tokenId);
        (uint256 maxLoan,) = ICollateralFacet(portfolioAccount).getMaxLoan();
        require(maxLoan > 0, "maxLoan must be > 0 to borrow");
        borrowed = (maxLoan * targetFractionBps) / 10000;
        require(borrowed > 0, "borrow target must be > 0");
        _borrow(borrowed);
        assertEq(ICollateralFacet(portfolioAccount).getTotalDebt(), borrowed, "debt should equal borrow");
    }

    /// @dev Run processRewards and return the emitted lender premium and the
    ///      lastEpochReward delta on the loan contract.
    function _processAndMeasure(uint256 rewardsAmount)
        internal
        returns (uint256 emittedPremium, uint256 epochRewardDelta, uint256 treasuryDelta)
    {
        deal(USDC, portfolioAccount, rewardsAmount);

        address treasury = prodConfig.getTreasury();
        uint256 treasuryBefore = IERC20(USDC).balanceOf(treasury);
        uint256 epochRewardBefore = LoanV2(payable(loanContract)).lastEpochReward();

        SwapMod.RouteParams[4] memory empty;
        vm.recordLogs();
        RewardsProcessingFacet(portfolioAccount).processRewards(tokenId, rewardsAmount, empty, 0);

        emittedPremium = _readLenderPremiumFromLogs();
        epochRewardDelta = LoanV2(payable(loanContract)).lastEpochReward() - epochRewardBefore;
        treasuryDelta = IERC20(USDC).balanceOf(treasury) - treasuryBefore;
    }

    /// @dev Parse the LenderPremiumPaid event amount from recorded logs.
    function _readLenderPremiumFromLogs() internal returns (uint256 amount) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != portfolioAccount) continue;
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != LENDER_PREMIUM_PAID_TOPIC) continue;
            // event LenderPremiumPaid(uint256 epoch, uint256 indexed tokenId, uint256 amount, address user, address asset)
            // non-indexed: epoch, amount, user, asset -> amount is the 2nd word.
            (, uint256 amt,,) = abi.decode(logs[i].data, (uint256, uint256, address, address));
            // indexed tokenId is topics[1].
            assertEq(uint256(logs[i].topics[1]), tokenId, "LenderPremiumPaid tokenId should match");
            amount = amt;
            found = true;
            break;
        }
        assertTrue(found, "LenderPremiumPaid event not emitted");
    }

    // --- Voting helpers (copied verbatim from LiveAerodromeVoting.t.sol) --

    /// @dev Returns up to `count` approved pools with alive gauges; approves known
    ///      fallback pools via the votingConfig owner if the approved list is short.
    function _getVotableApprovedPools(uint256 count) internal returns (address[] memory pools) {
        VotingConfig votingConfig = VotingConfig(votingConfigAddr);
        address[] memory approvedPools = votingConfig.getApprovedPoolsList();

        address[] memory alive = new address[](approvedPools.length + 2);
        uint256 aliveCount = 0;
        for (uint256 i = 0; i < approvedPools.length; i++) {
            address gauge = IVoter(VOTER).gauges(approvedPools[i]);
            if (gauge != address(0) && IVoter(VOTER).isAlive(gauge)) {
                alive[aliveCount] = approvedPools[i];
                aliveCount++;
                if (aliveCount >= count) break;
            }
        }

        if (aliveCount >= count) {
            pools = new address[](count);
            for (uint256 i = 0; i < count; i++) {
                pools[i] = alive[i];
            }
            return pools;
        }

        address[] memory fallbacks = new address[](2);
        fallbacks[0] = USDC_AERO_POOL;
        fallbacks[1] = WETH_USDC_POOL;

        address votingConfigOwner = votingConfig.owner();
        for (uint256 i = 0; i < fallbacks.length && aliveCount < count; i++) {
            bool alreadyIncluded = false;
            for (uint256 j = 0; j < aliveCount; j++) {
                if (alive[j] == fallbacks[i]) {
                    alreadyIncluded = true;
                    break;
                }
            }
            if (alreadyIncluded) continue;

            address gauge = IVoter(VOTER).gauges(fallbacks[i]);
            if (gauge != address(0) && IVoter(VOTER).isAlive(gauge)) {
                if (!votingConfig.isApprovedPool(fallbacks[i])) {
                    vm.prank(votingConfigOwner);
                    votingConfig.setApprovedPool(fallbacks[i], true);
                }
                alive[aliveCount] = fallbacks[i];
                aliveCount++;
            }
        }

        require(aliveCount >= count, "Not enough votable pools with alive gauges found");

        pools = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            pools[i] = alive[i];
        }
    }

    /// @dev Warps FORWARD to 3 days into the next epoch, dodging Aerodrome's
    ///      DistributeWindow (first hour) and SpecialVotingWindow (last hour).
    function _warpToSafeVotingTime() internal {
        uint256 currentTs = block.timestamp;
        uint256 nextEpoch = currentTs - (currentTs % 1 weeks) + 1 weeks;
        vm.warp(nextEpoch + 3 days);
    }

    // --- Scenario E: repeated vote -> claim -> process across two epochs --

    /// @dev Mission-critical pipeline run TWICE. Cycle 1 is below-kink LTV; cycle 2
    ///      is driven above the kink via a real multiplier cut. Each cycle votes,
    ///      hits claimFees as a no-op (asserting locked collateral is unchanged),
    ///      then processes and asserts the curve-correct lender premium is diverted.
    ///      Any revert anywhere fails the test (the mission-critical bar).
    function test_RepeatedLifecycle_VoteClaimProcess_TwiceAcrossEpochs() public {
        // --- Cycle 1: below the kink -------------------------------------
        // a. ~80% LTV, comfortably below the 15000 kink.
        _addCollateralAndBorrow(8000);

        // b. land in a safe voting window.
        _warpToSafeVotingTime();

        // c. vote on a single approved pool at full weight.
        address[] memory pools = _getVotableApprovedPools(1);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;
        uint256 voteTs1 = block.timestamp;
        _singleMulticallAsUser(
            abi.encodeWithSelector(VotingFacet.vote.selector, tokenId, pools, weights)
        );
        assertGe(IVoter(VOTER).lastVoted(tokenId), voteTs1, "cycle1 vote should register lastVoted");

        // d. claim is a no-op hit; locked collateral must not move across it.
        uint256 lockedBefore1 = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        ClaimingFacet(portfolioAccount).claimFees(new address[](0), new address[][](0), tokenId);
        assertEq(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            lockedBefore1,
            "cycle1 claim must not change locked collateral"
        );

        // e. process: assert below-kink curve premium is diverted.
        uint256 ltv1 = _healthLtv();
        assertLt(ltv1, CURVE_KINK, "cycle1 LTV must be below the kink");
        uint256 expected1 = (REWARDS_AMOUNT * prodConfig.getLenderPremium(ltv1)) / 10000;
        (uint256 emitted1, uint256 epochDelta1,) = _processAndMeasure(REWARDS_AMOUNT);
        assertEq(emitted1, expected1, "cycle1 emitted premium == rewards * rate / 1e4");
        assertEq(epochDelta1, expected1, "cycle1 lastEpochReward delta == premium");
        assertGt(emitted1, 0, "cycle1 premium must be nonzero");

        // --- Advance one full epoch (FORWARD only) -----------------------
        vm.warp(block.timestamp + WEEK);

        // --- Cycle 2: above the kink -------------------------------------
        // f. re-borrow first (process cleared debt to 0; premium path needs debt).
        //    Borrow at the normal multiplier BEFORE the cut, mirroring the
        //    above-kink flow-through test's ordering.
        (uint256 maxLoan2,) = ICollateralFacet(portfolioAccount).getMaxLoan();
        require(maxLoan2 > 0, "cycle2 maxLoan must be > 0");
        _borrow((maxLoan2 * 9500) / 10000);

        // g. cut the multiplier to push the real LTV above the kink.
        vm.prank(PROD_OWNER_SAFE);
        prodConfig.setMultiplier(MULTIPLIER / 2);

        // h. land in a fresh safe voting window.
        _warpToSafeVotingTime();

        // i. vote again; fresh epoch so no AlreadyVoted revert.
        uint256 voteTs2 = block.timestamp;
        _singleMulticallAsUser(
            abi.encodeWithSelector(VotingFacet.vote.selector, tokenId, pools, weights)
        );
        assertGe(IVoter(VOTER).lastVoted(tokenId), voteTs2, "cycle2 vote should register lastVoted");

        // j. claim no-op hit; locked collateral unchanged across it.
        uint256 lockedBefore2 = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        ClaimingFacet(portfolioAccount).claimFees(new address[](0), new address[][](0), tokenId);
        assertEq(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            lockedBefore2,
            "cycle2 claim must not change locked collateral"
        );

        // k. process: assert above-kink (SLOPE2 band) curve premium is diverted.
        uint256 ltv2 = _healthLtv();
        assertGt(ltv2, CURVE_KINK, "cycle2 LTV must be above the kink");
        assertLt(ltv2, 30000, "cycle2 LTV must be below the cap-binding threshold");
        uint256 expected2 = (REWARDS_AMOUNT * prodConfig.getLenderPremium(ltv2)) / 10000;
        (uint256 emitted2, uint256 epochDelta2,) = _processAndMeasure(REWARDS_AMOUNT);
        assertEq(emitted2, expected2, "cycle2 emitted premium == rewards * rate / 1e4");
        assertEq(epochDelta2, expected2, "cycle2 lastEpochReward delta == premium");
        assertGt(emitted2, 0, "cycle2 premium must be nonzero");

        // Headline: the above-kink cycle diverts strictly more of the same rewards.
        assertGt(emitted2, emitted1, "above-kink cycle must divert more than below-kink cycle");
    }

    // --- Scenario A: below the kink --------------------------------------

    function test_FlowThrough_BelowKink_LTV() public {
        // Borrow ~80% of maxLoan -> LTV ~8000 bps, comfortably below the 15000 kink.
        _addCollateralAndBorrow(8000);

        uint256 healthLtv = _healthLtv();
        assertLt(healthLtv, CURVE_KINK, "LTV must be below the kink");

        uint256 expectedRate = prodConfig.getLenderPremium(healthLtv);
        // Below-kink band: base + slopeBelow*ltv/1e4; bounded by base and base+slopeBelow*kink/1e4.
        assertGe(expectedRate, CURVE_BASE, "below-kink rate >= base");
        assertLt(expectedRate, CURVE_BASE + (CURVE_SLOPE_BELOW * CURVE_KINK) / 10000, "below-kink rate < kink-edge");
        uint256 expectedPremium = (REWARDS_AMOUNT * expectedRate) / 10000;

        (uint256 emittedPremium, uint256 epochRewardDelta, uint256 treasuryDelta) = _processAndMeasure(REWARDS_AMOUNT);

        assertEq(emittedPremium, expectedPremium, "emitted premium == rewards * rate / 1e4");
        assertEq(epochRewardDelta, expectedPremium, "lastEpochReward delta == premium");
        assertEq(treasuryDelta, (REWARDS_AMOUNT * TREASURY_FEE) / 10000, "treasury delta == rewards * 500 / 1e4");
    }

    // --- Scenario B: above the kink, below the cap -----------------------

    function test_FlowThrough_AboveKink_LTV() public {
        // Borrow near cap, then halve the multiplier to roughly double the real LTV.
        _addCollateralAndBorrow(9500);

        vm.prank(PROD_OWNER_SAFE);
        prodConfig.setMultiplier(MULTIPLIER / 2); // lower <= 2x current is always allowed

        uint256 healthLtv = _healthLtv();
        // Above the kink but below the cap-binding threshold (rate < cap implies ltv < 30000).
        assertGt(healthLtv, CURVE_KINK, "LTV must be above the kink");
        assertLt(healthLtv, 30000, "LTV must be below the cap-binding threshold");

        uint256 expectedRate = prodConfig.getLenderPremium(healthLtv);
        assertGt(expectedRate, prodConfig.getLenderPremium(CURVE_KINK), "above-kink rate > rate at kink");
        assertLt(expectedRate, CURVE_CAP, "above-kink rate must be below cap");
        uint256 expectedPremium = (REWARDS_AMOUNT * expectedRate) / 10000;

        (uint256 emittedPremium, uint256 epochRewardDelta, uint256 treasuryDelta) = _processAndMeasure(REWARDS_AMOUNT);

        assertEq(emittedPremium, expectedPremium, "emitted premium == rewards * rate / 1e4");
        assertEq(epochRewardDelta, expectedPremium, "lastEpochReward delta == premium");
        assertEq(treasuryDelta, (REWARDS_AMOUNT * TREASURY_FEE) / 10000, "treasury delta == rewards * 500 / 1e4");
    }

    // --- Scenario C: cap binding -----------------------------------------

    function test_FlowThrough_CapBinding_LTV() public {
        // Borrow near cap, then cut the multiplier hard to push LTV >= 30000 (>= 300%),
        // where the curve clamps to the cap.
        _addCollateralAndBorrow(9500);

        // 52 -> 13 multiplies LTV by ~4x, well past the 30000 cap threshold.
        vm.prank(PROD_OWNER_SAFE);
        prodConfig.setMultiplier(13);

        uint256 healthLtv = _healthLtv();
        assertGe(healthLtv, 30000, "LTV must be at/above the cap-binding threshold");

        uint256 expectedRate = prodConfig.getLenderPremium(healthLtv);
        assertEq(expectedRate, CURVE_CAP, "rate must clamp to cap (4500)");
        uint256 expectedPremium = (REWARDS_AMOUNT * CURVE_CAP) / 10000;

        (uint256 emittedPremium, uint256 epochRewardDelta, uint256 treasuryDelta) = _processAndMeasure(REWARDS_AMOUNT);

        assertEq(emittedPremium, expectedPremium, "emitted premium == rewards * 4500 / 1e4");
        assertEq(epochRewardDelta, expectedPremium, "lastEpochReward delta == premium");
        assertEq(treasuryDelta, (REWARDS_AMOUNT * TREASURY_FEE) / 10000, "treasury delta == rewards * 500 / 1e4");
    }

    // --- Scenario D: differential cross-check ----------------------------

    function test_Differential_HigherLtvDivertsMoreToLenders() public {
        // Below-kink leg. processRewards repays debt with the post-fee remainder,
        // so the debt clears after this call; re-borrow before the above-kink leg.
        _addCollateralAndBorrow(8000);
        uint256 ltvBelow = _healthLtv();
        assertLt(ltvBelow, CURVE_KINK, "below leg LTV must be below kink");
        (uint256 premiumBelow,,) = _processAndMeasure(REWARDS_AMOUNT);

        // Re-borrow near cap, then halve the multiplier to drive a real
        // underwater LTV above the kink, and process the same amount again.
        (uint256 maxLoan2,) = ICollateralFacet(portfolioAccount).getMaxLoan();
        uint256 borrow2 = (maxLoan2 * 9500) / 10000;
        _borrow(borrow2);
        vm.prank(PROD_OWNER_SAFE);
        prodConfig.setMultiplier(MULTIPLIER / 2);
        uint256 ltvAbove = _healthLtv();
        assertGt(ltvAbove, CURVE_KINK, "above leg LTV must be above kink");
        (uint256 premiumAbove,,) = _processAndMeasure(REWARDS_AMOUNT);

        // Headline: higher LTV diverts strictly more of the same rewards to lenders.
        assertGt(premiumAbove, premiumBelow, "above-kink premium must exceed below-kink premium");
    }

    // --- Regression guard: underwater account must still be able to vote -----

    /// @dev Guards the af2f22b underwater-account brick regression. Voting runs
    ///      through PortfolioManager.multicall, which ends by looping
    ///      enforceCollateralRequirements(); the regression made an underwater
    ///      account's enforce revert, bricking it. This proves an account that is
    ///      genuinely live-underwater (getLoanUtilization() > 100_00) can still
    ///      vote without reverting and stays usable across epochs.
    function test_UnderwaterAccount_CanStillVote_NotBricked() public {
        // a. borrow ~95% of maxLoan at the normal multiplier (enforce passes here).
        uint256 borrowed = _addCollateralAndBorrow(9500);

        // b. cut the multiplier 52 -> 13 (~4x LTV jump) as the config owner. This
        //    lowers maxLoan (read live) but never writes undercollateralizedDebt.
        vm.prank(PROD_OWNER_SAFE);
        prodConfig.setMultiplier(MULTIPLIER / 4);

        // live LTV > 100_00 but stored undercollateralizedDebt == 0 -- the brick scenario.
        uint256 ltv = _healthLtv();
        assertGt(ltv, 100_00, "account must be underwater before the vote");
        assertGt(ltv, 150_00, "underwater well above the kink");

        // c. land in a safe voting window.
        _warpToSafeVotingTime();

        address[] memory pools = _getVotableApprovedPools(1);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;

        // FIRST underwater vote -- the direct brick guard. The multicall's
        // end-of-tx enforce is the gate the regression tripped. A non-zero
        // lastVoted after this proves the vote registered on-chain. Read the
        // on-chain stamp rather than a cached block.timestamp local (via-ir
        // caches block.timestamp across warps).
        _singleMulticallAsUser(
            abi.encodeWithSelector(VotingFacet.vote.selector, tokenId, pools, weights)
        );
        uint256 lastVoted1 = IVoter(VOTER).lastVoted(tokenId);
        assertGt(lastVoted1, 0, "vote must register lastVoted");
        assertGt(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            0,
            "collateral intact after vote"
        );
        assertEq(ICollateralFacet(portfolioAccount).getTotalDebt(), borrowed, "debt unchanged by vote");
        assertGt(_healthLtv(), 100_00, "still underwater and readable after vote");

        // d. advance one epoch, stay underwater (no re-borrow), vote again ->
        //    proves not bricked for subsequent multicalls.
        vm.warp(block.timestamp + WEEK);
        _warpToSafeVotingTime();

        address[] memory pools2 = _getVotableApprovedPools(1);
        uint256[] memory weights2 = new uint256[](1);
        weights2[0] = 10000;

        _singleMulticallAsUser(
            abi.encodeWithSelector(VotingFacet.vote.selector, tokenId, pools2, weights2)
        );
        // Compare on-chain stamps: a strict increase proves the second vote
        // landed in a later epoch and did not revert/brick.
        assertGt(IVoter(VOTER).lastVoted(tokenId), lastVoted1, "second vote must advance lastVoted past the first");
        assertEq(ICollateralFacet(portfolioAccount).getTotalDebt(), borrowed, "debt still unchanged after second vote");
        assertGt(_healthLtv(), 100_00, "still underwater after second vote -- account not bricked");
    }
}
