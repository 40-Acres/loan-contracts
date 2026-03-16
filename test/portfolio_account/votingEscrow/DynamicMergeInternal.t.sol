// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {DynamicVotingEscrowFacet} from "../../../src/facets/account/votingEscrow/DynamicVotingEscrowFacet.sol";
import {DynamicCollateralFacet} from "../../../src/facets/account/collateral/DynamicCollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {DynamicLocalSetup} from "../utils/DynamicLocalSetup.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";

/**
 * @title DynamicMergeInternalTest
 * @dev Integration tests for DynamicVotingEscrowFacet.mergeInternal().
 *      Uses DynamicLocalSetup (DynamicCollateralManager + DynamicFeesVault).
 *      All calls go through PortfolioManager.multicall.
 */
contract DynamicMergeInternalTest is Test, DynamicLocalSetup {
    address internal _externalUser = address(0xbeef);
    address internal _otherUser = address(0xcafe);

    function setUp() public override {
        super.setUp();
        _registerMergeInternalSelector();
    }

    function _registerMergeInternalSelector() internal {
        vm.startPrank(FORTY_ACRES_DEPLOYER);

        // Get the old facet address from the registry via any existing selector
        address oldFacet = _facetRegistry.selectorToFacet(DynamicVotingEscrowFacet.createLock.selector);

        DynamicVotingEscrowFacet votingEscrowFacet = new DynamicVotingEscrowFacet(
            address(_portfolioFactory),
            address(_ve), address(_voter)
        );
        bytes4[] memory sel = new bytes4[](5);
        sel[0] = DynamicVotingEscrowFacet.increaseLock.selector;
        sel[1] = DynamicVotingEscrowFacet.createLock.selector;
        sel[2] = DynamicVotingEscrowFacet.merge.selector;
        sel[3] = DynamicVotingEscrowFacet.onERC721Received.selector;
        sel[4] = DynamicVotingEscrowFacet.mergeInternal.selector;

        // Replace old facet with new one that includes mergeInternal
        _facetRegistry.replaceFacet(oldFacet, address(votingEscrowFacet), sel, "DynamicVotingEscrowFacet");

        vm.stopPrank();
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

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
        calldatas[0] = abi.encodeWithSelector(DynamicVotingEscrowFacet.createLock.selector, amount);
        bytes[] memory results = _portfolioManager.multicall(calldatas, factories);
        tokenId = abi.decode(results[0], (uint256));
        vm.stopPrank();
    }

    function _createExternalLock(address externalUser, uint256 amount) internal returns (uint256 tokenId) {
        address aeroToken = _ve.token();
        deal(aeroToken, externalUser, amount);
        vm.startPrank(externalUser);
        IERC20(aeroToken).approve(address(_ve), amount);
        tokenId = _ve.createLock(amount, 4 * 365 days);
        vm.stopPrank();
    }

    function _mergeInternalViaMulticall(uint256 fromToken, uint256 toToken) internal returns (bytes[] memory results) {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(DynamicVotingEscrowFacet.mergeInternal.selector, fromToken, toToken);
        results = _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 1: Happy path — merge two collateralized tokens
    // ═══════════════════════════════════════════════════════════════════════

    function testMergeInternal_HappyPath_Dynamic() public {
        uint256 tokenA = _createPortfolioLock(10e18);
        uint256 tokenB = _createPortfolioLock(5e18);

        uint256 collateralBefore = DynamicCollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralBefore, 15e18, "Total collateral should be 15e18 before merge");

        _mergeInternalViaMulticall(tokenA, tokenB);

        // fromToken should be burned
        vm.expectRevert();
        _ve.ownerOf(tokenA);

        // toToken should have combined locked amount
        IVotingEscrow.LockedBalance memory locked = _ve.locked(tokenB);
        assertEq(uint256(uint128(locked.amount)), 15e18, "toToken should have combined 15e18");

        // Total collateral unchanged
        uint256 collateralAfter = DynamicCollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter, 15e18, "Total collateral should remain 15e18");

        // fromToken collateral record removed
        uint256 fromCollateral = BaseCollateralFacet(_portfolioAccount).getLockedCollateral(tokenA);
        assertEq(fromCollateral, 0, "fromToken collateral should be removed");

        // toToken collateral record updated
        uint256 toCollateral = BaseCollateralFacet(_portfolioAccount).getLockedCollateral(tokenB);
        assertEq(toCollateral, 15e18, "toToken collateral should reflect combined amount");

        assertEq(_ve.ownerOf(tokenB), _portfolioAccount, "Portfolio should still own toToken");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 2: Merge with active votes on fromToken
    // ═══════════════════════════════════════════════════════════════════════

    function testMergeInternal_WithActiveVotes_Dynamic() public {
        uint256 tokenA = _createPortfolioLock(10e18);
        uint256 tokenB = _createPortfolioLock(5e18);

        // Simulate an active vote on tokenA directly on the mock
        _mockVoter.setLastVoted(tokenA, block.timestamp);
        _mockVe.voting(tokenA);

        uint256 lastVoted = _mockVoter.lastVoted(tokenA);
        assertGt(lastVoted, 0, "tokenA should have lastVoted set");

        _mergeInternalViaMulticall(tokenA, tokenB);

        uint256 lastVotedAfter = _mockVoter.lastVoted(tokenA);
        assertEq(lastVotedAfter, 0, "tokenA lastVoted should be reset");

        IVotingEscrow.LockedBalance memory locked = _ve.locked(tokenB);
        assertEq(uint256(uint128(locked.amount)), 15e18, "toToken should have combined 15e18");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 3: Merge with active debt (DynamicFeesVault)
    // ═══════════════════════════════════════════════════════════════════════

    function testMergeInternal_WithActiveDebt_Dynamic() public {
        // Use large collateral to support borrowing
        uint256 tokenA = _createPortfolioLock(10000e18);
        uint256 tokenB = _createPortfolioLock(5000e18);

        // Borrow via multicall
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

        uint256 debt = DynamicCollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(debt, 0, "Should have active debt");

        uint256 collateralBefore = DynamicCollateralFacet(_portfolioAccount).getTotalLockedCollateral();

        // mergeInternal should succeed — collateral total unchanged
        _mergeInternalViaMulticall(tokenA, tokenB);

        uint256 collateralAfter = DynamicCollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter, collateralBefore, "Total collateral unchanged after merge");

        IVotingEscrow.LockedBalance memory locked = _ve.locked(tokenB);
        assertEq(uint256(uint128(locked.amount)), 15000e18, "toToken should have combined value");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 4: Revert if fromToken == toToken
    // ═══════════════════════════════════════════════════════════════════════

    function testMergeInternal_RevertsWhenSameToken_Dynamic() public {
        uint256 tokenA = _createPortfolioLock(10e18);

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(DynamicVotingEscrowFacet.mergeInternal.selector, tokenA, tokenA);

        vm.expectRevert("SameNFT");
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 5: Revert if fromToken is NOT in account
    // ═══════════════════════════════════════════════════════════════════════

    function testMergeInternal_RevertsWhenFromTokenExternal_Dynamic() public {
        uint256 tokenA = _createExternalLock(_externalUser, 10e18);
        uint256 tokenB = _createPortfolioLock(5e18);

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(DynamicVotingEscrowFacet.mergeInternal.selector, tokenA, tokenB);

        vm.expectRevert("from not in account");
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 6: Revert if toToken is NOT in account
    // ═══════════════════════════════════════════════════════════════════════

    function testMergeInternal_RevertsWhenToTokenExternal_Dynamic() public {
        uint256 tokenA = _createPortfolioLock(10e18);
        uint256 tokenB = _createExternalLock(_externalUser, 5e18);

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(DynamicVotingEscrowFacet.mergeInternal.selector, tokenA, tokenB);

        vm.expectRevert("to not in account");
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 7: Other user cannot merge tokens in someone else's account
    // ═══════════════════════════════════════════════════════════════════════

    function testMergeInternal_RevertsWhenCalledByOtherUser_Dynamic() public {
        uint256 tokenA = _createPortfolioLock(10e18);
        uint256 tokenB = _createPortfolioLock(5e18);

        vm.startPrank(_otherUser);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(DynamicVotingEscrowFacet.mergeInternal.selector, tokenA, tokenB);

        // _otherUser's portfolio doesn't own these tokens
        vm.expectRevert("from not in account");
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }
}
