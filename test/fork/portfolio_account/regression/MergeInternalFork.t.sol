// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {BaseForkSetup} from "./BaseForkSetup.sol";
import {VotingEscrowFacet} from "../../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {VotingFacet} from "../../../../src/facets/account/vote/VotingFacet.sol";
import {CollateralFacet} from "../../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../../src/facets/account/lending/BaseLendingFacet.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";
import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../../../src/interfaces/IVoter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";

/**
 * @title MergeInternalFork
 * @dev Fork-based integration tests for VotingEscrowFacet.mergeInternal().
 *      Tests against real Base chain Velodrome contracts.
 */
contract MergeInternalFork is BaseForkSetup {
    uint256 constant LOCK_AMOUNT_1 = 100e18;
    uint256 constant LOCK_AMOUNT_2 = 200e18;

    // Well-known Aerodrome pool on Base for voting tests (vAMM-AERO/USDC)
    address constant AERO_USDC_POOL = 0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d;

    uint256 public tokenIdA;
    uint256 public tokenIdB;

    function setUp() public override {
        super.setUp();
        _upgradeVotingEscrowFacetWithMergeInternal();
        _approvePool(AERO_USDC_POOL);
    }

    // -----------------------------------------------------------------------
    // Setup helpers
    // -----------------------------------------------------------------------

    function _upgradeVotingEscrowFacetWithMergeInternal() internal {
        VotingEscrowFacet newVEFacet = new VotingEscrowFacet(
            address(portfolioFactory),
            VOTING_ESCROW,
            VOTER
        );

        bytes4[] memory newSelectors = new bytes4[](5);
        newSelectors[0] = VotingEscrowFacet.increaseLock.selector;
        newSelectors[1] = VotingEscrowFacet.createLock.selector;
        newSelectors[2] = VotingEscrowFacet.merge.selector;
        newSelectors[3] = VotingEscrowFacet.onERC721Received.selector;
        newSelectors[4] = VotingEscrowFacet.mergeInternal.selector;

        vm.prank(DEPLOYER);
        facetRegistry.replaceFacet(
            address(votingEscrowFacet),
            address(newVEFacet),
            newSelectors,
            "VotingEscrowFacet"
        );

        votingEscrowFacet = newVEFacet;
    }

    function _approvePool(address pool) internal {
        vm.prank(DEPLOYER);
        votingConfig.setApprovedPool(pool, true);
    }

    function _createLockInAccount(uint256 amount) internal returns (uint256 newTokenId) {
        deal(AERO, user, amount);
        vm.prank(user);
        IERC20(AERO).approve(portfolioAccount, amount);

        bytes[] memory results = _singleMulticallAsUser(
            abi.encodeWithSelector(VotingEscrowFacet.createLock.selector, amount)
        );

        newTokenId = abi.decode(results[0], (uint256));
    }

    function _voteWithToken(uint256 _tokenId, address pool) internal {
        address[] memory pools = new address[](1);
        pools[0] = pool;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;

        _singleMulticallAsUser(
            abi.encodeWithSelector(VotingFacet.vote.selector, _tokenId, pools, weights)
        );
    }

    // -----------------------------------------------------------------------
    // Test 1: Happy path - merge two createLock tokens (both permanent)
    //         mergeInternal calls unlockPermanent(fromToken) before merge
    // -----------------------------------------------------------------------

    function testMergeInternal_happyPath() public {
        tokenIdA = _createLockInAccount(LOCK_AMOUNT_1);
        tokenIdB = _createLockInAccount(LOCK_AMOUNT_2);

        // Both tokens are permanent (createLock → addLockedCollateral → lockPermanent)
        assertTrue(IVotingEscrow(VOTING_ESCROW).locked(tokenIdA).isPermanent);
        assertTrue(IVotingEscrow(VOTING_ESCROW).locked(tokenIdB).isPermanent);

        int128 amountA = IVotingEscrow(VOTING_ESCROW).locked(tokenIdA).amount;
        int128 amountB = IVotingEscrow(VOTING_ESCROW).locked(tokenIdB).amount;

        uint256 totalCollateralBefore = CollateralFacet(portfolioAccount).getTotalLockedCollateral();

        // Merge tokenIdA into tokenIdB
        _singleMulticallAsUser(
            abi.encodeWithSelector(VotingEscrowFacet.mergeInternal.selector, tokenIdA, tokenIdB)
        );

        // fromToken burned (ownerOf returns address(0) on real VE)
        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(tokenIdA),
            address(0),
            "fromToken should be burned"
        );

        // toToken has combined amount
        int128 mergedAmount = IVotingEscrow(VOTING_ESCROW).locked(tokenIdB).amount;
        assertEq(
            uint256(uint128(mergedAmount)),
            uint256(uint128(amountA)) + uint256(uint128(amountB)),
            "Merged token should have combined locked amount"
        );

        // Collateral tracking correct
        assertEq(BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenIdA), 0, "fromToken collateral should be 0");
        assertEq(
            BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenIdB),
            uint256(uint128(mergedAmount)),
            "toToken collateral should equal merged amount"
        );

        // Total collateral unchanged
        uint256 totalCollateralAfter = CollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(totalCollateralAfter, totalCollateralBefore, "Total collateral should be unchanged");
    }

    // -----------------------------------------------------------------------
    // Test 2: Merge with active votes on fromToken
    //         mergeInternal auto-resets votes and unlocks permanent
    // -----------------------------------------------------------------------

    function testMergeInternal_withActiveVotes() public {
        tokenIdA = _createLockInAccount(LOCK_AMOUNT_1);
        tokenIdB = _createLockInAccount(LOCK_AMOUNT_2);

        // Vote with tokenIdA
        _voteWithToken(tokenIdA, AERO_USDC_POOL);
        assertTrue(IVotingEscrow(VOTING_ESCROW).voted(tokenIdA), "tokenIdA should have voted");

        // Warp forward to next epoch so voter.reset() is allowed
        vm.warp(block.timestamp + 1 weeks);
        vm.roll(block.number + 1);

        int128 amountA = IVotingEscrow(VOTING_ESCROW).locked(tokenIdA).amount;
        int128 amountB = IVotingEscrow(VOTING_ESCROW).locked(tokenIdB).amount;

        // mergeInternal should auto-reset votes, unlock permanent, then merge
        _singleMulticallAsUser(
            abi.encodeWithSelector(VotingEscrowFacet.mergeInternal.selector, tokenIdA, tokenIdB)
        );

        // Verify merge succeeded - toToken has combined amount
        int128 mergedAmount = IVotingEscrow(VOTING_ESCROW).locked(tokenIdB).amount;
        assertEq(
            uint256(uint128(mergedAmount)),
            uint256(uint128(amountA)) + uint256(uint128(amountB)),
            "Merged token should have combined amount after vote reset"
        );
    }

    // -----------------------------------------------------------------------
    // Test 3: Other user cannot merge another user's tokens
    // -----------------------------------------------------------------------

    function testMergeInternal_otherUserCannotMerge() public {
        tokenIdA = _createLockInAccount(LOCK_AMOUNT_1);
        tokenIdB = _createLockInAccount(LOCK_AMOUNT_2);

        // Create a second user with their own portfolio
        address user2 = address(0xdead0002);
        portfolioFactory.createAccount(user2);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            VotingEscrowFacet.mergeInternal.selector, tokenIdA, tokenIdB
        );
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        // user2's multicall routes to user2's portfolio, which doesn't own these tokens
        vm.prank(user2);
        vm.expectRevert();
        portfolioManager.multicall(calldatas, factories);
    }

    // -----------------------------------------------------------------------
    // Test 4: Total collateral preserved after merge
    // -----------------------------------------------------------------------

    function testMergeInternal_collateralPreserved() public {
        tokenIdA = _createLockInAccount(LOCK_AMOUNT_1);
        tokenIdB = _createLockInAccount(LOCK_AMOUNT_2);

        uint256 collateralA = BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenIdA);
        uint256 collateralB = BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenIdB);
        uint256 totalBefore = CollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(totalBefore, collateralA + collateralB, "Total should be sum of both");

        _singleMulticallAsUser(
            abi.encodeWithSelector(VotingEscrowFacet.mergeInternal.selector, tokenIdA, tokenIdB)
        );

        uint256 totalAfter = CollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(totalAfter, totalBefore, "Total collateral must be preserved after merge");
        assertEq(
            BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenIdB),
            totalAfter,
            "Surviving token should hold all collateral"
        );
    }

    // -----------------------------------------------------------------------
    // Test 5: Revert cases
    // -----------------------------------------------------------------------

    function testMergeInternal_revertsSameToken() public {
        tokenIdA = _createLockInAccount(LOCK_AMOUNT_1);

        vm.expectRevert("SameNFT");
        _singleMulticallAsUser(
            abi.encodeWithSelector(VotingEscrowFacet.mergeInternal.selector, tokenIdA, tokenIdA)
        );
    }

    function testMergeInternal_revertsIfFromTokenNotInAccount() public {
        tokenIdB = _createLockInAccount(LOCK_AMOUNT_2);

        // Token 1 exists on-chain but is NOT in our account
        uint256 externalToken = 1;

        vm.expectRevert("from not in account");
        _singleMulticallAsUser(
            abi.encodeWithSelector(VotingEscrowFacet.mergeInternal.selector, externalToken, tokenIdB)
        );
    }

    function testMergeInternal_revertsIfToTokenNotInAccount() public {
        tokenIdA = _createLockInAccount(LOCK_AMOUNT_1);
        uint256 externalToken = 1;

        vm.expectRevert("to not in account");
        _singleMulticallAsUser(
            abi.encodeWithSelector(VotingEscrowFacet.mergeInternal.selector, tokenIdA, externalToken)
        );
    }

    // -----------------------------------------------------------------------
    // Test 6: Merge with active debt preserves collateral and debt
    //
    // Scenario: User borrows at a safe ratio, then merges two tokens.
    // Debt and total collateral must be identical before and after.
    // -----------------------------------------------------------------------

    function testMergeInternal_withDebt_preservesCollateralAndDebt() public {
        tokenIdA = _createLockInAccount(LOCK_AMOUNT_1);
        tokenIdB = _createLockInAccount(LOCK_AMOUNT_2);

        // Fund vault so borrow can succeed
        _fundVault(1_000_000e6);

        // Borrow 50% of max loan (safe ratio)
        (uint256 maxLoan,) = BaseCollateralFacet(portfolioAccount).getMaxLoan();
        uint256 borrowAmount = maxLoan * 50 / 100;
        _borrow(borrowAmount);

        // Snapshot before merge
        uint256 debtBefore = BaseCollateralFacet(portfolioAccount).getTotalDebt();
        uint256 totalCollateralBefore = CollateralFacet(portfolioAccount).getTotalLockedCollateral();
        uint256 collateralA = BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenIdA);
        uint256 collateralB = BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenIdB);

        assertGt(debtBefore, 0, "Should have debt");
        assertEq(totalCollateralBefore, collateralA + collateralB, "Total should be sum of both tokens");

        // Merge tokenIdA into tokenIdB
        _singleMulticallAsUser(
            abi.encodeWithSelector(VotingEscrowFacet.mergeInternal.selector, tokenIdA, tokenIdB)
        );

        // Debt unchanged
        uint256 debtAfter = BaseCollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debtAfter, debtBefore, "Debt should be unchanged after merge");

        // Total collateral unchanged
        uint256 totalCollateralAfter = CollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(totalCollateralAfter, totalCollateralBefore, "Total collateral should be unchanged");

        // fromToken collateral zeroed, toToken holds everything
        assertEq(BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenIdA), 0, "fromToken collateral should be 0");
        assertEq(
            BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenIdB),
            totalCollateralAfter,
            "toToken should hold all collateral"
        );

        // VE state: merged amount equals sum of lock amounts
        int128 mergedAmount = IVotingEscrow(VOTING_ESCROW).locked(tokenIdB).amount;
        assertEq(
            uint256(uint128(mergedAmount)),
            LOCK_AMOUNT_1 + LOCK_AMOUNT_2,
            "Merged token should have combined locked amount"
        );
    }

    // -----------------------------------------------------------------------
    // Test 7: Undercollateralized user cannot merge
    //
    // Scenario: User borrows, then admin lowers rewardsRate so user becomes
    // undercollateralized. Merge now correctly detects the shortfall and
    // reverts via enforceCollateralRequirements (since af2f22b).
    // -----------------------------------------------------------------------

    function testMergeInternal_undercollateralizedCannotMerge() public {
        tokenIdA = _createLockInAccount(LOCK_AMOUNT_1);
        tokenIdB = _createLockInAccount(LOCK_AMOUNT_2);

        // Fund vault so borrow can succeed
        _fundVault(1_000_000e6);

        // Borrow close to max loan
        (uint256 maxLoan,) = BaseCollateralFacet(portfolioAccount).getMaxLoan();
        uint256 borrowAmount = maxLoan * 90 / 100; // borrow 90% of max
        _borrow(borrowAmount);

        uint256 debtBefore = BaseCollateralFacet(portfolioAccount).getTotalDebt();
        assertGt(debtBefore, 0, "Should have debt");

        // Admin lowers rewardsRate to make the user undercollateralized
        // Current rate is 10000; halving it will roughly halve the maxLoan
        vm.prank(DEPLOYER);
        loanConfig.setRewardsRate(5000);

        // Verify user is now undercollateralized (maxLoan < debt)
        (uint256 newMaxLoan,) = BaseCollateralFacet(portfolioAccount).getMaxLoan();
        assertLt(newMaxLoan, debtBefore, "User should be undercollateralized after rate drop");

        // Merge reverts because enforceCollateralRequirements now correctly
        // detects the full shortfall when collateral delta is zero (prev==new).
        vm.expectRevert();
        _singleMulticallAsUser(
            abi.encodeWithSelector(VotingEscrowFacet.mergeInternal.selector, tokenIdA, tokenIdB)
        );
    }
}
