// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {VotingEscrowFacet} from "../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {LocalSetup} from "../utils/LocalSetup.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";

/**
 * @title MergeInternalTest
 * @dev Integration tests for VotingEscrowFacet.mergeInternal().
 *      All calls go through PortfolioManager.multicall to match production usage.
 *
 *      mergeInternal merges two veNFTs that are BOTH already deposited as collateral
 *      inside the portfolio account. It:
 *        1. Requires both tokens owned by the account (address(this))
 *        2. Requires fromToken != toToken
 *        3. Calls _voter.reset(fromToken) to clear votes before merge
 *        4. Calls _votingEscrow.merge(fromToken, toToken)
 *        5. Removes fromToken collateral record, updates toToken collateral value
 *        6. Emits LockMerged event
 */
contract MergeInternalTest is Test, LocalSetup {
    address internal _externalUser = address(0xbeef);
    address internal _otherUser = address(0xcafe);

    function setUp() public override {
        super.setUp();
        // Register mergeInternal selector on the VotingEscrowFacet.
        // The base LocalSetup only registers 4 selectors (increaseLock, createLock, merge, onERC721Received).
        // We need to re-deploy and re-register the facet with 5 selectors including mergeInternal.
        _registerMergeInternalSelector();
    }

    function _registerMergeInternalSelector() internal {
        vm.startPrank(FORTY_ACRES_DEPLOYER);

        // Get the old facet address from the registry via any existing selector
        address oldFacet = _facetRegistry.selectorToFacet(VotingEscrowFacet.createLock.selector);

        VotingEscrowFacet votingEscrowFacet = new VotingEscrowFacet(
            address(_portfolioFactory),
            address(_ve), address(_voter)
        );
        bytes4[] memory sel = new bytes4[](5);
        sel[0] = VotingEscrowFacet.increaseLock.selector;
        sel[1] = VotingEscrowFacet.createLock.selector;
        sel[2] = VotingEscrowFacet.merge.selector;
        sel[3] = VotingEscrowFacet.onERC721Received.selector;
        sel[4] = VotingEscrowFacet.mergeInternal.selector;

        // Replace old facet with new one that includes mergeInternal
        _facetRegistry.replaceFacet(oldFacet, address(votingEscrowFacet), sel, "VotingEscrowFacet");

        vm.stopPrank();
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    /// @dev Create a lock inside the portfolio account via PortfolioManager multicall.
    function _createPortfolioLock(uint256 amount) internal returns (uint256 tokenId) {
        address aeroToken = _ve.token();
        IERC20 aero = IERC20(aeroToken);

        deal(aeroToken, _user, amount);
        vm.prank(_user);
        aero.approve(_portfolioAccount, type(uint256).max);
        vm.prank(_portfolioAccount);
        aero.approve(address(_ve), type(uint256).max);

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(VotingEscrowFacet.createLock.selector, amount);
        bytes[] memory results = _portfolioManager.multicall(calldatas, factories);
        tokenId = abi.decode(results[0], (uint256));
        vm.stopPrank();
    }

    /// @dev Create a lock owned by an external user on VE directly (not in any portfolio).
    function _createExternalLock(address externalUser, uint256 amount) internal returns (uint256 tokenId) {
        address aeroToken = _ve.token();
        deal(aeroToken, externalUser, amount);
        vm.startPrank(externalUser);
        IERC20(aeroToken).approve(address(_ve), amount);
        tokenId = _ve.createLock(amount, 4 * 365 days);
        vm.stopPrank();
    }

    /// @dev Execute mergeInternal via PortfolioManager multicall as _user.
    function _mergeInternalViaMulticall(uint256 fromToken, uint256 toToken) internal returns (bytes[] memory results) {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(VotingEscrowFacet.mergeInternal.selector, fromToken, toToken);
        results = _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 1: Happy path — merge two collateralized tokens
    // ═══════════════════════════════════════════════════════════════════════

    function testMergeInternal_HappyPath() public {
        // Create two portfolio-owned locks
        uint256 tokenA = _createPortfolioLock(10e18);
        uint256 tokenB = _createPortfolioLock(5e18);

        uint256 collateralBefore = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralBefore, 15e18, "Total collateral should be 15e18 before merge");

        // Merge tokenA into tokenB
        _mergeInternalViaMulticall(tokenA, tokenB);

        // fromToken (tokenA) should be burned — ownerOf should revert
        vm.expectRevert();
        _ve.ownerOf(tokenA);

        // toToken (tokenB) should have combined locked amount
        IVotingEscrow.LockedBalance memory locked = _ve.locked(tokenB);
        assertEq(uint256(uint128(locked.amount)), 15e18, "toToken should have combined 15e18");

        // Total collateral should be unchanged (value moved, not destroyed)
        uint256 collateralAfter = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter, 15e18, "Total collateral should remain 15e18 after merge");

        // fromToken collateral record should be zero
        uint256 fromCollateral = BaseCollateralFacet(_portfolioAccount).getLockedCollateral(tokenA);
        assertEq(fromCollateral, 0, "fromToken collateral should be removed");

        // toToken collateral record should reflect combined amount
        uint256 toCollateral = BaseCollateralFacet(_portfolioAccount).getLockedCollateral(tokenB);
        assertEq(toCollateral, 15e18, "toToken collateral should reflect combined amount");

        // Portfolio account still owns toToken
        assertEq(_ve.ownerOf(tokenB), _portfolioAccount, "Portfolio should still own toToken");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 2: Merge with active votes on fromToken — reset called automatically
    // ═══════════════════════════════════════════════════════════════════════

    function testMergeInternal_WithActiveVotes() public {
        uint256 tokenA = _createPortfolioLock(10e18);
        uint256 tokenB = _createPortfolioLock(5e18);

        // Simulate an active vote on tokenA by setting lastVoted directly on the mock.
        // Going through VotingFacet.vote requires approved pools which the mock doesn't support.
        _mockVoter.setLastVoted(tokenA, block.timestamp);
        _mockVe.voting(tokenA); // Mark the VE as voted (prevents transfers)

        // Verify lastVoted is set
        uint256 lastVoted = _mockVoter.lastVoted(tokenA);
        assertGt(lastVoted, 0, "tokenA should have lastVoted set after voting");

        // mergeInternal should succeed because it auto-resets votes via _voter.reset()
        _mergeInternalViaMulticall(tokenA, tokenB);

        // Verify reset was called: lastVoted should be 0 after reset
        uint256 lastVotedAfter = _mockVoter.lastVoted(tokenA);
        assertEq(lastVotedAfter, 0, "tokenA lastVoted should be reset to 0");

        // Verify the merge completed
        IVotingEscrow.LockedBalance memory locked = _ve.locked(tokenB);
        assertEq(uint256(uint128(locked.amount)), 15e18, "toToken should have combined 15e18");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 3: Merge with active debt — collateral requirements still pass
    // ═══════════════════════════════════════════════════════════════════════

    function testMergeInternal_WithActiveDebt() public {
        // Create two portfolio-owned locks with large collateral
        uint256 tokenA = _createPortfolioLock(10000e18);
        uint256 tokenB = _createPortfolioLock(5000e18);

        // Seed vault with USDC for borrowing
        _mockUsdc.mint(_vault, 100_000e6);

        // Borrow some amount via multicall
        uint256 borrowAmount = 100e6;
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            bytes4(keccak256("borrow(uint256)")),
            borrowAmount
        );
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        // Verify debt exists
        uint256 debt = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(debt, 0, "Should have active debt");

        uint256 collateralBefore = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();

        // mergeInternal should succeed — total collateral is unchanged so requirements still pass
        _mergeInternalViaMulticall(tokenA, tokenB);

        uint256 collateralAfter = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter, collateralBefore, "Total collateral should be unchanged after merge");

        // Verify toToken has combined amount
        IVotingEscrow.LockedBalance memory locked = _ve.locked(tokenB);
        assertEq(uint256(uint128(locked.amount)), 15000e18, "toToken should have combined value");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 4: Revert if fromToken == toToken
    // ═══════════════════════════════════════════════════════════════════════

    function testMergeInternal_RevertsWhenSameToken() public {
        uint256 tokenA = _createPortfolioLock(10e18);

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(VotingEscrowFacet.mergeInternal.selector, tokenA, tokenA);

        vm.expectRevert("SameNFT");
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 5: Revert if fromToken is NOT in account (external token)
    // ═══════════════════════════════════════════════════════════════════════

    function testMergeInternal_RevertsWhenFromTokenExternal() public {
        uint256 tokenA = _createExternalLock(_externalUser, 10e18);
        uint256 tokenB = _createPortfolioLock(5e18);

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(VotingEscrowFacet.mergeInternal.selector, tokenA, tokenB);

        vm.expectRevert("from not in account");
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 6: Revert if toToken is NOT in account (external token)
    // ═══════════════════════════════════════════════════════════════════════

    function testMergeInternal_RevertsWhenToTokenExternal() public {
        uint256 tokenA = _createPortfolioLock(10e18);
        uint256 tokenB = _createExternalLock(_externalUser, 5e18);

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(VotingEscrowFacet.mergeInternal.selector, tokenA, tokenB);

        vm.expectRevert("to not in account");
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 7: Another user cannot merge tokens in someone else's account
    // ═══════════════════════════════════════════════════════════════════════

    function testMergeInternal_RevertsWhenCalledByOtherUser() public {
        uint256 tokenA = _createPortfolioLock(10e18);
        uint256 tokenB = _createPortfolioLock(5e18);

        // _otherUser tries to call mergeInternal on _user's tokens via PortfolioManager.
        // multicall looks up the caller's own portfolio, so _otherUser's portfolio is a
        // different account that does NOT own tokenA/tokenB.
        vm.startPrank(_otherUser);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(VotingEscrowFacet.mergeInternal.selector, tokenA, tokenB);

        // This should revert because _otherUser's portfolio does not own the tokens.
        // The multicall creates a portfolio for _otherUser if it doesn't exist, then
        // calls mergeInternal on THAT portfolio, where the tokens are not present.
        vm.expectRevert("from not in account");
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }
}
