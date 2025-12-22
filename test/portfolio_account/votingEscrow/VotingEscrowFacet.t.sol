// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {VotingEscrowFacet} from "../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {Setup} from "../utils/Setup.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";

contract VotingEscrowFacetTest is Test, Setup {
    
    // Helper function to create lock via PortfolioManager multicall and return the tokenId
    function createLockViaMulticall(uint256 amount) internal returns (uint256 tokenId) {
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            VotingEscrowFacet.createLock.selector,
            amount
        );
        bytes[] memory results = _portfolioManager.multicall(calldatas, portfolios);
        require(results.length > 0, "Multicall failed - no results");
        // Decode the tokenId from the return data
        tokenId = abi.decode(results[0], (uint256));
        vm.stopPrank();
    }

    // Helper function for tests that expect reverts - doesn't catch the revert
    function createLockViaMulticallExpectRevert(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            VotingEscrowFacet.createLock.selector,
            amount
        );
        // Let the revert bubble up naturally
        _portfolioManager.multicall(calldatas, portfolios);
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
}

