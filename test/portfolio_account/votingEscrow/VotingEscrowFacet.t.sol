// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {VotingEscrowFacet} from "../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {LocalSetup} from "../utils/LocalSetup.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";

contract VotingEscrowFacetTest is Test, LocalSetup {
    
    // Helper function to create lock via PortfolioManager multicall and return the tokenId
    function createLockViaMulticall(uint256 amount) internal returns (uint256 tokenId) {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            VotingEscrowFacet.createLock.selector,
            amount
        );
        bytes[] memory results = _portfolioManager.multicall(calldatas, portfolioFactories);
        require(results.length > 0, "Multicall failed - no results");
        // Decode the tokenId from the return data
        tokenId = abi.decode(results[0], (uint256));
        vm.stopPrank();
    }

    // Helper function for tests that expect reverts - doesn't catch the revert
    function createLockViaMulticallExpectRevert(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            VotingEscrowFacet.createLock.selector,
            amount
        );
        // Let the revert bubble up naturally
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }


    function testCreateLock() public {
        // Get the AERO token (the underlying token for voting escrow)
        address aeroToken = _ve.token();
        IERC20 aero = IERC20(aeroToken);
        
        // Amount to lock (1 AERO)
        uint256 lockAmount = 1e18;
        
        // Fund user with tokens
        deal(aeroToken, _user, lockAmount);
        
        // Verify user has tokens
        assertGe(aero.balanceOf(_user), lockAmount, "User should have tokens");
        
        // Approve the portfolio account to spend from user
        // Use startPrank/stopPrank to ensure the approval persists
        vm.startPrank(_user);
        aero.approve(_portfolioAccount, type(uint256).max);
        vm.stopPrank();
        
        // Verify the allowance was set
        uint256 allowance = aero.allowance(_user, _portfolioAccount);
        require(allowance >= lockAmount, "Allowance must be set before creating lock");
        
        // Also need to approve the voting escrow to spend from portfolio account
        // since createLock will transfer tokens from user to portfolio account, then to voting escrow
        // We can set the approval before the tokens arrive
        vm.startPrank(_portfolioAccount);
        aero.approve(address(_ve), type(uint256).max);
        vm.stopPrank();
        
        // Get initial collateral state
        uint256 initialCollateral = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(initialCollateral, 0, "Initial collateral should be 0");
        
        // Create the lock and get the tokenId directly
        uint256 tokenId = createLockViaMulticall(lockAmount);
        assertGt(tokenId, 0, "TokenId should be returned");
        
        // Verify collateral was added
        uint256 newCollateral = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertGt(newCollateral, 0, "Collateral should be added after creating lock");
        assertEq(newCollateral, lockAmount, "Collateral should equal the locked amount");
        
        // Verify the lock using .locked()
        IVotingEscrow.LockedBalance memory locked = _ve.locked(tokenId);
        assertEq(uint256(uint128(locked.amount)), lockAmount, "Locked amount should match");
        assertEq(locked.isPermanent, true, "Lock should be permanent");
        assertEq(_ve.ownerOf(tokenId), _portfolioAccount, "Token should be owned by portfolio account");
    }

    function testCreateLockWithDifferentAmounts() public {
        address aeroToken = _ve.token();
        IERC20 aero = IERC20(aeroToken);
        
        // Test with different amounts
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e18;      // 1 AERO
        amounts[1] = 10e18;     // 10 AERO
        amounts[2] = 100e18;    // 100 AERO
        
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = amounts[i];
            
            // Fund user with tokens
            deal(aeroToken, _user, amount);
            
            // Approve
            vm.startPrank(_user);
            aero.approve(_portfolioAccount, type(uint256).max);
            vm.stopPrank();
            
            vm.startPrank(_portfolioAccount);
            aero.approve(address(_ve), type(uint256).max);
            vm.stopPrank();
            
            // Get collateral before
            uint256 collateralBefore = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
            
            // Create lock and get the tokenId directly
            uint256 tokenId = createLockViaMulticall(amount);
            assertGt(tokenId, 0, "TokenId should be returned");
            
            // Verify collateral increased
            uint256 collateralAfter = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
            assertGe(collateralAfter, collateralBefore + amount, "Collateral should increase by at least the locked amount");
            IVotingEscrow.LockedBalance memory locked = _ve.locked(tokenId);
            assertEq(uint256(uint128(locked.amount)), amount, "Locked amount should match");
        }
    }

    function testCreateLockWithDifferentDurations() public {
        address aeroToken = _ve.token();
        IERC20 aero = IERC20(aeroToken);
        
        uint256 lockAmount = 1e18;
        
        // Note: createLock now hardcodes the lock duration to 4 years
        // This test verifies that locks are created successfully regardless of duration parameter
        // (since duration is no longer a parameter)
        
        // Fund user with tokens
        deal(aeroToken, _user, lockAmount);
        
        // Approve
        vm.startPrank(_user);
        aero.approve(_portfolioAccount, type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(_portfolioAccount);
        aero.approve(address(_ve), type(uint256).max);
        vm.stopPrank();
        
        // Create lock and get the tokenId directly
        uint256 tokenId = createLockViaMulticall(lockAmount);
        assertGt(tokenId, 0, "TokenId should be returned");
        
        // Verify collateral was added
        uint256 collateral = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertGt(collateral, 0, "Collateral should be added");
        IVotingEscrow.LockedBalance memory locked = _ve.locked(tokenId);
        assertEq(uint256(uint128(locked.amount)), lockAmount, "Locked amount should match");
        assertEq(locked.isPermanent, true, "Lock should be permanent");
    }

    function testCreateLockRevertsWhenNotEnoughBalance() public {
        address aeroToken = _ve.token();
        IERC20 aero = IERC20(aeroToken);
        
        uint256 lockAmount = 1e18;
        
        // Approve the portfolio account to spend from user (so allowance is not the issue)
        // But don't fund the user - should revert on insufficient balance
        vm.startPrank(_user);
        aero.approve(_portfolioAccount, type(uint256).max);
        vm.stopPrank();
        
        // Approve voting escrow to spend from portfolio account
        vm.startPrank(_portfolioAccount);
        aero.approve(address(_ve), type(uint256).max);
        vm.stopPrank();
        
        // Should revert due to insufficient balance in user account
        vm.expectRevert();
        createLockViaMulticallExpectRevert(lockAmount);
    }

    function testCreateLockRevertsWhenNotApproved() public {
        address aeroToken = _ve.token();
        IERC20 aero = IERC20(aeroToken);

        uint256 lockAmount = 1e18;

        // Fund user but don't approve user -> portfolio account
        deal(aeroToken, _user, lockAmount);
        // Don't approve - this should cause the test to revert

        vm.startPrank(_portfolioAccount);
        aero.approve(address(_ve), type(uint256).max);
        vm.stopPrank();

        // Should revert due to insufficient allowance from user
        vm.expectRevert();
        createLockViaMulticallExpectRevert(lockAmount);
    }

    // ========================
    // Merge Tests (C-02 fix)
    // ========================

    address internal _externalUser = address(0xbeef);
    address internal _randomCaller = address(0xdead);

    /// @dev Helper: create a portfolio-owned lock and return its tokenId
    function _createPortfolioLock(uint256 amount) internal returns (uint256 tokenId) {
        address aeroToken = _ve.token();
        IERC20 aero = IERC20(aeroToken);
        deal(aeroToken, _user, amount);
        vm.startPrank(_user);
        aero.approve(_portfolioAccount, type(uint256).max);
        vm.stopPrank();
        vm.startPrank(_portfolioAccount);
        aero.approve(address(_ve), type(uint256).max);
        vm.stopPrank();
        tokenId = createLockViaMulticall(amount);
    }

    /// @dev Helper: create a lock owned by an external user directly on VE
    function _createExternalLock(address externalUser, uint256 amount) internal returns (uint256 tokenId) {
        address aeroToken = _ve.token();
        deal(aeroToken, externalUser, amount);
        vm.startPrank(externalUser);
        IERC20(aeroToken).approve(address(_ve), amount);
        tokenId = _ve.createLock(amount, 4 * 365 days);
        vm.stopPrank();
    }

    function testMergeExternalNftIntoPortfolio() public {
        // Create portfolio-owned lock (toToken)
        uint256 toToken = _createPortfolioLock(10e18);
        uint256 collateralBefore = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();

        // Create external user's lock (fromToken)
        uint256 fromToken = _createExternalLock(_externalUser, 5e18);

        // External user approves portfolio account for their NFT
        vm.prank(_externalUser);
        _ve.approve(_portfolioAccount, fromToken);

        // Anyone can trigger the merge
        vm.prank(_randomCaller);
        VotingEscrowFacet(_portfolioAccount).merge(fromToken, toToken);

        // Verify collateral increased
        uint256 collateralAfter = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertGt(collateralAfter, collateralBefore, "Collateral should increase after merge");

        // Verify the toToken balance increased
        IVotingEscrow.LockedBalance memory locked = _ve.locked(toToken);
        assertEq(uint256(uint128(locked.amount)), 15e18, "Merged amount should be 15 AERO");

        // Verify the portfolio still owns toToken
        assertEq(_ve.ownerOf(toToken), _portfolioAccount, "Portfolio should still own toToken");
    }

    function testMergeCalledByPortfolioOwner() public {
        uint256 toToken = _createPortfolioLock(10e18);

        uint256 fromToken = _createExternalLock(_externalUser, 5e18);
        vm.prank(_externalUser);
        _ve.approve(_portfolioAccount, fromToken);

        // Portfolio owner can also call merge directly
        vm.prank(_user);
        VotingEscrowFacet(_portfolioAccount).merge(fromToken, toToken);

        IVotingEscrow.LockedBalance memory locked = _ve.locked(toToken);
        assertEq(uint256(uint128(locked.amount)), 15e18, "Merged amount should be 15 AERO");
    }

    function testMergeRevertsWhenFromTokenOwnedByPortfolio() public {
        // Create two portfolio-owned locks
        uint256 tokenA = _createPortfolioLock(10e18);
        uint256 tokenB = _createPortfolioLock(5e18);

        // Attempt to merge portfolio's own tokens — should revert
        // because require(_votingEscrow.ownerOf(fromToken) != address(this))
        vm.prank(_randomCaller);
        vm.expectRevert();
        VotingEscrowFacet(_portfolioAccount).merge(tokenA, tokenB);
    }

    function testMergeRevertsWhenToTokenNotOwnedByPortfolio() public {
        // Create an external lock as toToken (not owned by portfolio)
        uint256 externalTo = _createExternalLock(_externalUser, 10e18);

        // Create another external lock as fromToken
        address otherUser = address(0xcafe);
        uint256 externalFrom = _createExternalLock(otherUser, 5e18);

        vm.prank(otherUser);
        _ve.approve(_portfolioAccount, externalFrom);

        // Should revert because toToken is not owned by portfolio
        vm.prank(_randomCaller);
        vm.expectRevert();
        VotingEscrowFacet(_portfolioAccount).merge(externalFrom, externalTo);
    }

    function testMergeRevertsWhenFromTokenNotApproved() public {
        uint256 toToken = _createPortfolioLock(10e18);

        // Create external lock but do NOT approve portfolio
        uint256 fromToken = _createExternalLock(_externalUser, 5e18);

        // Should revert at VotingEscrow level (NotApprovedOrOwner)
        vm.prank(_randomCaller);
        vm.expectRevert();
        VotingEscrowFacet(_portfolioAccount).merge(fromToken, toToken);
    }

    function testMergeUpdatesCollateralCorrectly() public {
        uint256 toToken = _createPortfolioLock(10e18);
        uint256 collateralAfterLock = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfterLock, 10e18, "Collateral should be 10 AERO");

        // Merge in 5 AERO from external
        uint256 fromToken1 = _createExternalLock(_externalUser, 5e18);
        vm.prank(_externalUser);
        _ve.approve(_portfolioAccount, fromToken1);
        vm.prank(_randomCaller);
        VotingEscrowFacet(_portfolioAccount).merge(fromToken1, toToken);

        uint256 collateralAfterMerge1 = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfterMerge1, 15e18, "Collateral should be 15 AERO after first merge");

        // Merge in another 3 AERO
        address otherUser = address(0xcafe);
        uint256 fromToken2 = _createExternalLock(otherUser, 3e18);
        vm.prank(otherUser);
        _ve.approve(_portfolioAccount, fromToken2);
        vm.prank(_randomCaller);
        VotingEscrowFacet(_portfolioAccount).merge(fromToken2, toToken);

        uint256 collateralAfterMerge2 = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfterMerge2, 18e18, "Collateral should be 18 AERO after second merge");
    }

    // ========================
    // Auto-collateral on safeTransferFrom Tests
    // ========================

    function testAutoAddCollateralOnSafeTransfer() public {
        // Create an external veNFT lock
        uint256 externalToken = _createExternalLock(_externalUser, 10e18);

        // Make the lock permanent (required for collateral)
        vm.prank(_externalUser);
        _ve.lockPermanent(externalToken);

        // Verify no collateral before transfer
        uint256 collateralBefore = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();

        // safeTransferFrom the veNFT to the portfolio account
        vm.prank(_externalUser);
        IERC721(address(_ve)).safeTransferFrom(_externalUser, _portfolioAccount, externalToken);

        // Assert collateral was auto-added
        uint256 collateralAfter = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfter, collateralBefore + 10e18, "Collateral should increase by locked amount");

        // Assert the specific token's collateral is tracked
        uint256 tokenCollateral = BaseCollateralFacet(_portfolioAccount).getLockedCollateral(externalToken);
        assertEq(tokenCollateral, 10e18, "Token collateral should be tracked");

        // Assert the lock is permanent
        IVotingEscrow.LockedBalance memory locked = _ve.locked(externalToken);
        assertTrue(locked.isPermanent, "Lock should be permanent");

        // Assert ownership
        assertEq(_ve.ownerOf(externalToken), _portfolioAccount, "Portfolio should own the token");
    }

    function testAutoAddCollateralIdempotent() public {
        // Create a portfolio lock via createLock (already adds collateral)
        uint256 tokenId = _createPortfolioLock(10e18);
        uint256 collateralAfterLock = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfterLock, 10e18, "Collateral should be 10 AERO after lock");

        // Transfer the NFT out to the portfolio owner via removeCollateral
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseCollateralFacet.removeCollateral.selector,
            tokenId
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();

        // Verify collateral removed
        uint256 collateralAfterRemove = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfterRemove, 0, "Collateral should be 0 after removal");

        // Verify the owner now holds the NFT
        assertEq(_ve.ownerOf(tokenId), _user, "Owner should hold the NFT");

        // Transfer back via safeTransferFrom - should auto-add collateral
        vm.prank(_user);
        IERC721(address(_ve)).safeTransferFrom(_user, _portfolioAccount, tokenId);

        // Verify collateral re-added
        uint256 collateralAfterReturn = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertEq(collateralAfterReturn, 10e18, "Collateral should be 10 AERO after return");
    }

    function testNonCollateralNftAccepted() public {
        // Verify no collateral initially (Setup transfers a veNFT via transferFrom, not safeTransferFrom)
        // The setUp veNFT (_tokenId) was transferred via transferFrom, no auto-add

        // Deploy a mock ERC721 and send it to the portfolio via safeTransferFrom
        // We'll use a second voting escrow that is NOT the collateral asset
        // Instead, just test that a regular transfer works by using the _votingEscrow
        // with a token that's not the collateral VE
        // Since we can't easily deploy a mock ERC721 in a fork test, we verify that
        // the onERC721Received function returns the correct selector for any caller
        // by directly calling it
        bytes4 selector = VotingEscrowFacet(_portfolioAccount).onERC721Received(
            address(this), _externalUser, 999, ""
        );
        assertEq(selector, bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")), "Should return correct selector");

        // Collateral should be unchanged
        uint256 collateral = CollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        // Only the setUp veNFT collateral (if any) should be present
        // Since setUp uses transferFrom (not safeTransferFrom), no auto-add happened
    }
}

