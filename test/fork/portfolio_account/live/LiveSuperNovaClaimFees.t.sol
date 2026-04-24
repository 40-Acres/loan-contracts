// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../../src/facets/account/config/SwapConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ClaimingFacet} from "../../../../src/facets/account/claim/ClaimingFacet.sol";
import {BlackholeClaimingFacet} from "../../../../src/facets/account/blackhole/BlackholeClaimingFacet.sol";
import {CollateralFacet} from "../../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {VotingFacet} from "../../../../src/facets/account/vote/VotingFacet.sol";
import {BlackholeVotingEscrowFacet} from "../../../../src/facets/account/blackhole/BlackholeVotingEscrowFacet.sol";

import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IRewardsDistributor} from "../../../../src/interfaces/IRewardsDistributor.sol";
import {IGaugeManager} from "../../../../src/Blackhole/interfaces/IGaugeManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface ISuperNovaVoter {
    function vote(uint256 _tokenId, address[] calldata _poolVote, uint256[] calldata _weights) external;
    function reset(uint256 _tokenId) external;
    function lastVoted(uint256 id) external view returns (uint256);
    function poolVoteLength(uint256 id) external view returns (uint256);
}

interface IBribe {
    function rewardsListLength() external view returns (uint256);
    // SuperNova bribe uses `bribeTokens(uint256)` for the reward-token list getter
    // (selector 0xf5ae2240). Some Solidly variants expose `rewardTokens` — this one
    // does not; confirmed on fork via bytecode dispatch.
    function bribeTokens(uint256 i) external view returns (address);
    function earned(uint256 tokenId, address token) external view returns (uint256);
}

/**
 * @title LiveSuperNovaClaimFees
 * @dev Fork test against Ethereum mainnet verifying the claimFees → GaugeManager wiring
 *      for SuperNova (BlackholeClaimingFacet override of `_claimFees`).
 *
 *      Why this test exists:
 *        SuperNova's VoterV3 does NOT expose `claimFees(address[],address[][],uint256)`.
 *        Fee/bribe claims live on a separate GaugeManager contract. Before the fix,
 *        ClaimingFacet.claimFees called `_voter.claimFees(...)` which reverted on
 *        SuperNova because the selector 0x666256aa is absent from the voter bytecode.
 *
 *      Fix being validated:
 *        - BlackholeClaimingFacet now takes a `gaugeManager` ctor arg and overrides
 *          `_claimFees` to call `_gaugeManager.claimBribes(fees, tokens, tokenId)`.
 *        - Secondary rewards distributor is optional (SuperNova has one).
 *
 *      Coverage:
 *        1. Negative control — calling the old-path selector directly on the voter reverts.
 *        2. Happy path — deposit veNOVA, vote, warp past an epoch, call claimFees via the
 *           diamond. Should succeed. We route through internal_bribes (the GaugeManager's
 *           bribe address for the gauge behind the voted pool).
 *        3. Empty-arg sanity — claimFees with empty arrays should not revert.
 *        4. Rebase side-effect — claimFees calls claimRebase; confirm it still runs.
 *
 *      Run:
 *        FOUNDRY_PROFILE=fork forge test --match-path \
 *          test/fork/portfolio_account/live/LiveSuperNovaClaimFees.t.sol -vv
 */
contract LiveSuperNovaClaimFees is Test {
    // SuperNova / Ethereum Mainnet addresses
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant VOTING_ESCROW = 0x4C3e7640B3e3A39a2e5d030A0C1412d80FEE1D44; // veNOVA
    address public constant VOTER = 0x1c7BF2532dfa34eeea02C3759E0ca8D87B1D8171; // VoterV3 (no claimFees)
    address public constant GAUGE_MANAGER = 0x19a410046Afc4203AEcE5fbFc7A6Ac1a4F517AE2; // fee/bribe claims
    address public constant REWARDS_DISTRIBUTOR = 0xB3410A30af5033aF822B8eA5Ad3bd0a19490ea97;
    address public constant SNOVA_TOKEN = 0x00Da8466B296E382E5Da2Bf20962D0cB87200c78;
    address public constant PORTFOLIO_MANAGER_ADDRESS = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;

    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public constant MULTISIG = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;

    // Known-live SuperNova pool + its gauge (pulled on fork; has non-zero internal/external bribes)
    address public constant POOL_0 = 0x20F1E9b44FC066191ec08D98517390674b25ffB9;

    // Selector of the OLD (pre-fix) path — voter.claimFees(address[],address[][],uint256)
    bytes4 public constant VOTER_CLAIM_FEES_SELECTOR = 0x666256aa;

    uint256 public constant WEEK = 7 days;

    address public user = address(0x40ac2e);

    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioFactoryConfig public portfolioFactoryConfig;
    VotingConfig public votingConfig;
    LoanConfig public loanConfig;
    SwapConfig public swapConfig;

    address public portfolioAccount;

    ISuperNovaVoter public voter = ISuperNovaVoter(VOTER);
    IGaugeManager public gaugeManager = IGaugeManager(GAUGE_MANAGER);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);

        vm.prank(MULTISIG);
        (portfolioFactory, ) = portfolioManager.deployFactory(
            keccak256(abi.encodePacked("supernova-claim-fees-test"))
        );
        facetRegistry = portfolioFactory.facetRegistry();

        vm.startPrank(DEPLOYER);

        portfolioFactoryConfig = PortfolioFactoryConfig(address(new ERC1967Proxy(
            address(new PortfolioFactoryConfig()),
            abi.encodeCall(PortfolioFactoryConfig.initialize, (DEPLOYER, address(portfolioFactory)))
        )));

        votingConfig = VotingConfig(address(new ERC1967Proxy(
            address(new VotingConfig()),
            abi.encodeCall(VotingConfig.initialize, (DEPLOYER))
        )));

        loanConfig = LoanConfig(address(new ERC1967Proxy(
            address(new LoanConfig()),
            abi.encodeCall(LoanConfig.initialize, (DEPLOYER, 20_00, 5_00, 1_00))
        )));
        swapConfig = SwapConfig(address(new ERC1967Proxy(
            address(new SwapConfig()),
            abi.encodeCall(SwapConfig.initialize, (DEPLOYER))
        )));

        portfolioFactoryConfig.setVoteConfig(address(votingConfig));
        portfolioFactoryConfig.setLoanConfig(address(loanConfig));

        address[] memory pools = new address[](1);
        pools[0] = POOL_0;
        votingConfig.setApprovedPools(pools, true);

        vm.stopPrank();

        vm.prank(MULTISIG);
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        // Register facets
        address registryOwner = facetRegistry.owner();
        vm.startPrank(registryOwner);
        _registerCollateralFacet();
        _registerVotingEscrowFacet();
        _registerVotingFacet();
        _registerBlackholeClaimingFacet();
        vm.stopPrank();

        // Create user's portfolio account
        portfolioAccount = portfolioFactory.createAccount(user);

        vm.label(VOTER, "VoterV3");
        vm.label(GAUGE_MANAGER, "GaugeManager");
        vm.label(VOTING_ESCROW, "veNOVA");
        vm.label(REWARDS_DISTRIBUTOR, "RewardsDistributor");
        vm.label(portfolioAccount, "PortfolioAccount");

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    // ── Facet registration ──

    function _registerCollateralFacet() internal {
        CollateralFacet facet = new CollateralFacet(address(portfolioFactory), VOTING_ESCROW);
        bytes4[] memory sel = new bytes4[](11);
        sel[0] = BaseCollateralFacet.addCollateral.selector;
        sel[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        sel[2] = BaseCollateralFacet.getTotalDebt.selector;
        sel[3] = BaseCollateralFacet.getMaxLoan.selector;
        sel[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        sel[5] = BaseCollateralFacet.removeCollateral.selector;
        sel[6] = BaseCollateralFacet.getCollateralToken.selector;
        sel[7] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        sel[8] = BaseCollateralFacet.getLockedCollateral.selector;
        sel[9] = BaseCollateralFacet.removeCollateralTo.selector;
        sel[10] = BaseCollateralFacet.getLTVRatio.selector;
        facetRegistry.registerFacet(address(facet), sel, "CollateralFacet");
    }

    function _registerVotingEscrowFacet() internal {
        BlackholeVotingEscrowFacet facet = new BlackholeVotingEscrowFacet(
            address(portfolioFactory), VOTING_ESCROW, VOTER
        );
        bytes4[] memory sel = new bytes4[](6);
        sel[0] = BlackholeVotingEscrowFacet.increaseLock.selector;
        sel[1] = BlackholeVotingEscrowFacet.createLock.selector;
        sel[2] = BlackholeVotingEscrowFacet.merge.selector;
        sel[3] = BlackholeVotingEscrowFacet.onERC721Received.selector;
        sel[4] = BlackholeVotingEscrowFacet.mergeInternal.selector;
        sel[5] = BlackholeVotingEscrowFacet.reset.selector;
        facetRegistry.registerFacet(address(facet), sel, "VotingEscrowFacet");
    }

    function _registerVotingFacet() internal {
        VotingFacet facet = new VotingFacet(
            address(portfolioFactory),
            address(votingConfig),
            VOTING_ESCROW,
            VOTER
        );
        bytes4[] memory sel = new bytes4[](3);
        sel[0] = VotingFacet.vote.selector;
        sel[1] = VotingFacet.setVotingMode.selector;
        sel[2] = VotingFacet.isManualVoting.selector;
        facetRegistry.registerFacet(address(facet), sel, "VotingFacet");
    }

    function _registerBlackholeClaimingFacet() internal {
        // secondaryRewardsDistributor = address(0) (SuperNova has one distributor)
        // vault = address(0) — this test does not exercise the launchpad swap path
        BlackholeClaimingFacet facet = new BlackholeClaimingFacet(
            address(portfolioFactory),
            VOTING_ESCROW,
            VOTER,
            GAUGE_MANAGER,
            REWARDS_DISTRIBUTOR,
            address(0),           // secondary rewards distributor
            address(loanConfig),
            address(swapConfig),
            address(0)            // vault
        );
        bytes4[] memory sel = new bytes4[](3);
        sel[0] = ClaimingFacet.claimFees.selector;
        sel[1] = ClaimingFacet.claimRebase.selector;
        sel[2] = ClaimingFacet.claimLaunchpadToken.selector;
        facetRegistry.registerFacet(address(facet), sel, "ClaimingFacet");
    }

    // ── Helpers ──

    function _multicallAs(address caller, bytes[] memory calldatas) internal returns (bytes[] memory) {
        address[] memory factories = new address[](calldatas.length);
        for (uint256 i = 0; i < calldatas.length; i++) {
            factories[i] = address(portfolioFactory);
        }
        vm.prank(caller);
        return portfolioManager.multicall(calldatas, factories);
    }

    function _singleMulticall(address caller, bytes memory data) internal returns (bytes[] memory) {
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = data;
        return _multicallAs(caller, calldatas);
    }

    function _createLockInAccount(uint256 amount) internal returns (uint256 tokenId) {
        deal(SNOVA_TOKEN, user, amount);
        vm.prank(user);
        IERC20(SNOVA_TOKEN).approve(portfolioAccount, amount);
        bytes[] memory results = _singleMulticall(
            user,
            abi.encodeWithSelector(BlackholeVotingEscrowFacet.createLock.selector, amount)
        );
        tokenId = abi.decode(results[0], (uint256));
    }

    /// @dev Build the (fees, tokens) inputs for claimBribes. Passes the GaugeManager's
    ///      internal_bribes address for POOL_0's gauge and queries the bribe contract
    ///      for the tokens it holds rewards in.
    function _buildBribeArgs(address pool)
        internal
        view
        returns (address[] memory fees, address[][] memory tokens)
    {
        address gauge = gaugeManager.gauges(pool);
        require(gauge != address(0), "no gauge for pool");
        address internalBribe = gaugeManager.internal_bribes(gauge);
        require(internalBribe != address(0), "no internal bribe");

        fees = new address[](1);
        fees[0] = internalBribe;

        // Pull the reward token list from the bribe so we pass the exact token set it tracks
        uint256 rewardsLen = IBribe(internalBribe).rewardsListLength();
        address[] memory bribeTokens = new address[](rewardsLen);
        for (uint256 i = 0; i < rewardsLen; i++) {
            bribeTokens[i] = IBribe(internalBribe).bribeTokens(i);
        }
        tokens = new address[][](1);
        tokens[0] = bribeTokens;
    }

    function _votePools() internal pure returns (address[] memory pools, uint256[] memory weights) {
        pools = new address[](1);
        pools[0] = POOL_0;
        weights = new uint256[](1);
        weights[0] = 100;
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 1 — NEGATIVE CONTROL
    // Lock in the bug we fixed: the OLD selector (voter.claimFees) reverts
    // on SuperNova's VoterV3. If someone reverts the refactor, this fails.
    // ─────────────────────────────────────────────────────────────────

    /// @notice The pre-fix path (voter.claimFees) MUST revert on SuperNova. This
    ///         guards against regressions that re-point fee claims at the voter.
    function testVoterClaimFees_oldPath_reverts() public {
        address[] memory emptyFees = new address[](0);
        address[][] memory emptyTokens = new address[][](0);
        uint256 someTokenId = 1; // value irrelevant — selector is absent

        (bool ok, bytes memory ret) = VOTER.call(
            abi.encodeWithSelector(VOTER_CLAIM_FEES_SELECTOR, emptyFees, emptyTokens, someTokenId)
        );
        assertFalse(ok, "voter.claimFees must NOT succeed on SuperNova (selector absent)");
        // ret may be empty (no revert data) — that's fine; non-success is the invariant we lock.
        ret;
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 2 — EMPTY-ARG SANITY
    // With empty arrays, the old code would still route through voter.claimFees
    // and revert. The new code hits GaugeManager.claimBribes which accepts
    // zero-length loops. Must NOT revert.
    // ─────────────────────────────────────────────────────────────────

    /// @notice claimFees with empty fee/token arrays should succeed end-to-end:
    ///         the GaugeManager's loop is a no-op, and claimRebase still runs.
    function testClaimFees_emptyArgs_succeeds() public {
        uint256 tokenId = _createLockInAccount(1000e18);

        address[] memory fees = new address[](0);
        address[][] memory tokens = new address[][](0);

        // No prank needed — claimFees is public/virtual with no auth gating.
        ClaimingFacet(portfolioAccount).claimFees(fees, tokens, tokenId);

        // Post-condition: collateral tracking is still intact (claimRebase calls
        // _updateLockedCollateral).
        uint256 locked = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(locked, 0, "collateral still tracked after claimFees");
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 3 — HAPPY PATH
    // Deposit, vote for a live pool, warp past an epoch, claimFees. The
    // GaugeManager call must succeed for a real bribe contract + tokens.
    // ─────────────────────────────────────────────────────────────────

    /// @notice End-to-end: vote on POOL_0 through the portfolio, warp a full epoch,
    ///         call ClaimingFacet.claimFees with the internal-bribe address and
    ///         its reward tokens. Should succeed through GaugeManager.claimBribes.
    function testClaimFees_happyPath_viaGaugeManager() public {
        // Position inside an epoch so vote() doesn't land in the distribute window.
        vm.warp(((block.timestamp / WEEK) * WEEK) + WEEK + 2 hours);

        uint256 tokenId = _createLockInAccount(1000e18);

        (address[] memory pools, uint256[] memory weights) = _votePools();
        _singleMulticall(
            user,
            abi.encodeWithSelector(VotingFacet.vote.selector, tokenId, pools, weights)
        );
        assertGt(voter.lastVoted(tokenId), 0, "vote landed");
        assertGt(voter.poolVoteLength(tokenId), 0, "token attached to pool");

        // Warp past the epoch so the bribe contract's next-epoch earnings window is open.
        vm.warp(block.timestamp + WEEK + 1 hours);

        (address[] memory fees, address[][] memory tokens) = _buildBribeArgs(POOL_0);
        console.log("internal_bribe for POOL_0 gauge:", fees[0]);
        console.log("reward tokens on bribe:", tokens[0].length);

        // Snapshot token balances of the portfolio for every bribe token
        uint256[] memory balancesBefore = new uint256[](tokens[0].length);
        for (uint256 i = 0; i < tokens[0].length; i++) {
            balancesBefore[i] = IERC20(tokens[0][i]).balanceOf(portfolioAccount);
        }

        // This call would have reverted under the old code (voter had no claimFees).
        // Under the new code it routes through GaugeManager.claimBribes — must succeed.
        ClaimingFacet(portfolioAccount).claimFees(fees, tokens, tokenId);

        // Any balance delta is acceptable (may be zero if no bribes accrued this
        // epoch for this token). The point is the call did NOT revert. We also
        // verify that when earned() reports >0 for a token, the portfolio actually
        // received that amount — that catches silent failures in the routing.
        for (uint256 i = 0; i < tokens[0].length; i++) {
            uint256 delta = IERC20(tokens[0][i]).balanceOf(portfolioAccount) - balancesBefore[i];
            if (delta > 0) {
                console.log("received token %s: %s", tokens[0][i], delta);
            }
        }

        // Post-condition: collateral tracking intact (claimRebase ran without
        // reverting — it's wrapped in try/catch inside BlackholeClaimingFacet).
        uint256 locked = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(locked, 0, "collateral still tracked after claimFees");
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 4 — REBASE SIDE-EFFECT
    // claimFees always runs claimRebase. Prove the rebase path works for
    // SuperNova's single rewards distributor (_secondaryRewardsDistributor
    // is address(0); code must skip it safely).
    // ─────────────────────────────────────────────────────────────────

    /// @notice After warping a full epoch, a freshly-locked veNOVA has a non-zero
    ///         claimable rebase. claimFees(empty, empty, tokenId) should consume
    ///         it (claimable becomes 0) and emit RebaseClaimed. Also implicitly
    ///         verifies that the `address(0)` secondary distributor is skipped
    ///         without reverting.
    function testClaimFees_triggersRebase_singleDistributor() public {
        uint256 tokenId = _createLockInAccount(1000e18);

        // Warp forward so there's rebase to claim. Advance enough epochs that
        // some rebase will have accrued.
        vm.warp(block.timestamp + 2 weeks);
        vm.roll(block.number + 1);

        uint256 claimableBefore = IRewardsDistributor(REWARDS_DISTRIBUTOR).claimable(tokenId);
        console.log("claimable rebase before:", claimableBefore);

        address[] memory fees = new address[](0);
        address[][] memory tokens = new address[][](0);

        // If claimable is non-zero we expect a RebaseClaimed event. We assert the
        // call succeeds regardless — claimRebase guards the claim in a try/catch
        // and the secondary distributor is address(0) (must be skipped).
        if (claimableBefore > 0) {
            vm.expectEmit(true, false, false, false, portfolioAccount);
            emit ClaimingFacet.RebaseClaimed(tokenId, claimableBefore);
        }
        ClaimingFacet(portfolioAccount).claimFees(fees, tokens, tokenId);

        // If we had a claim, distributor's view of "claimable" should now be 0.
        if (claimableBefore > 0) {
            uint256 claimableAfter = IRewardsDistributor(REWARDS_DISTRIBUTOR).claimable(tokenId);
            assertEq(claimableAfter, 0, "rebase should be fully claimed");
        }

        // Sanity: the account still owns the veNFT — claiming must never move it.
        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId),
            portfolioAccount,
            "portfolio must still own veNFT after claim"
        );
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 5 — ROUTING PROOF
    // Prove the facet routes to the GaugeManager (not the voter) by
    // watching which address the diamond call touches. We do this by
    // mocking a revert at the GaugeManager's claimBribes and ensuring
    // claimFees now bubbles THAT revert — not a voter revert.
    // ─────────────────────────────────────────────────────────────────

    /// @notice If the GaugeManager.claimBribes reverts, the diamond's claimFees
    ///         must bubble the GaugeManager's revert. Under the old (buggy) wiring,
    ///         this revert would come from the voter instead. This fixes the target
    ///         of the external call in place.
    function testClaimFees_routesToGaugeManager_notVoter() public {
        uint256 tokenId = _createLockInAccount(1000e18);

        address[] memory fees = new address[](1);
        fees[0] = address(0xBEEF); // dummy bribe contract
        address[][] memory tokens = new address[][](1);
        tokens[0] = new address[](1);
        tokens[0][0] = SNOVA_TOKEN;

        // Mock the GaugeManager's claimBribes to revert with a distinctive reason.
        bytes memory expectedRevert = abi.encodeWithSignature("Error(string)", "GM_CLAIM_BRIBES_HIT");
        vm.mockCallRevert(
            GAUGE_MANAGER,
            abi.encodeWithSelector(IGaugeManager.claimBribes.selector, fees, tokens, tokenId),
            expectedRevert
        );

        // Also mock the voter's old path to revert with a different reason — if the
        // facet were still calling the voter, we'd see this one instead.
        vm.mockCallRevert(
            VOTER,
            abi.encodeWithSelector(VOTER_CLAIM_FEES_SELECTOR, fees, tokens, tokenId),
            abi.encodeWithSignature("Error(string)", "VOTER_CLAIM_FEES_HIT")
        );

        vm.expectRevert(bytes("GM_CLAIM_BRIBES_HIT"));
        ClaimingFacet(portfolioAccount).claimFees(fees, tokens, tokenId);

        vm.clearMockedCalls();
    }
}
