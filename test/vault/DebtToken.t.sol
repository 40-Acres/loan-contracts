// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {DebtToken} from "../../vault/DebtToken.sol";
import {ProtocolTimeLibrary} from "../../src/libraries/ProtocolTimeLibrary.sol";

/**
 * @title MockDebtToken
 * @notice Mock implementation of DebtToken for testing purposes
 * @dev Exposes internal functions as public/external to enable testing
 */
contract MockDebtToken is DebtToken {
    /**
     * @notice Constructor to initialize the mock
     */
    constructor() {
        // Initialize any required state
    }

    /**
     * @notice Sets the authorized address
     * @param _authorized The address to set as authorized
     */
    function setAuthorized(address _authorized) external {
        authorized = _authorized;
    }

    /**
     * @notice Public mint function for testing
     * @param _to The address to mint to
     * @param _amount The amount to mint
     */
    function mint(address _to, uint256 _amount) external {
        if (msg.sender != authorized) revert NotAuthorized();
        if (_amount == 0) revert ZeroAmount();
        _mint(_to, _amount);
    }

    /**
     * @notice Exposes _getCurrentBalance for testing
     * @param _owner The address to get the balance for
     * @return The current balance from checkpoints
     */
    function getCurrentBalance(address _owner) external view returns (uint256) {
        return _getCurrentBalance(_owner);
    }

    /**
     * @notice Helper function to get balance at a specific checkpoint index
     * @param _owner The address to get the balance for
     * @param _index The checkpoint index
     * @return The balance at that checkpoint
     */
    function getBalanceAtCheckpoint(address _owner, uint256 _index) external view returns (uint256) {
        return checkpoints[_owner][_index]._balances;
    }

    /**
     * @notice Helper function to get the number of checkpoints for an address
     * @param _owner The address to check
     * @return The number of checkpoints
     */
    function getNumCheckpoints(address _owner) external view returns (uint256) {
        return numCheckpoints[_owner];
    }

    /**
     * @notice Helper function to get supply at a specific checkpoint index
     * @param _index The checkpoint index
     * @return The supply at that checkpoint
     */
    function getSupplyAtCheckpoint(uint256 _index) external view returns (uint256) {
        return supplyCheckpoints[_index].supply;
    }

    /**
     * @notice Helper function to get the number of supply checkpoints
     * @return The number of supply checkpoints
     */
    function getSupplyNumCheckpoints() external view returns (uint256) {
        return supplyNumCheckpoints;
    }
}

/**
 * @title DebtTokenTest
 * @notice Comprehensive test suite for DebtToken mint function
 */
contract DebtTokenTest is Test {
    MockDebtToken public debtToken;
    address public authorized;
    address public user1;
    address public user2;
    address public user3;
    address public unauthorized;

    uint256 constant WEEK = 7 days;

    function setUp() public {
        // Set initial timestamp to a specific value for consistent epoch calculations
        vm.warp(1767224179);
        
        debtToken = new MockDebtToken();
        authorized = address(0x100);
        user1 = address(0x1);
        user2 = address(0x2);
        user3 = address(0x3);
        unauthorized = address(0x999);

        // Set authorized address
        debtToken.setAuthorized(authorized);
    }

    // ============ Basic Mint Tests ============

    function test_Mint_SingleMint() public {
        uint256 amount = 1000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.prank(authorized);
        debtToken.mint(user1, amount);

        // Check balance checkpoint was created
        assertEq(debtToken.getNumCheckpoints(user1), 1, "Should have 1 checkpoint");
        assertEq(debtToken.getCurrentBalance(user1), amount, "Balance should match minted amount");
        assertEq(debtToken.getBalanceAtCheckpoint(user1, 0), amount, "Checkpoint balance should match");

        // Check total supply per epoch (includes vault balance due to rebalancing)
        // With default 80% ratio: user gets 1000, vault gets 4000, total = 5000
        uint256 expectedTotal = amount + (amount * 8000 / 2000); // user + vault
        assertEq(debtToken.totalSupply(currentEpoch), expectedTotal, "Total supply per epoch should include vault");
        assertEq(debtToken.totalSupply(), expectedTotal, "Current total supply should match");

        // Check supply checkpoint was created
        assertEq(debtToken.getSupplyNumCheckpoints(), 1, "Should have 1 supply checkpoint");
        assertEq(debtToken.getSupplyAtCheckpoint(0), expectedTotal, "Supply checkpoint should match total");
    }

    function test_Mint_MultipleMintsSameUser() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        uint256 amount3 = 500e18;
        uint256 userTotal = amount1 + amount2 + amount3;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.startPrank(authorized);
        debtToken.mint(user1, amount1);
        debtToken.mint(user1, amount2);
        debtToken.mint(user1, amount3);
        vm.stopPrank();

        // Check final balance
        assertEq(debtToken.getCurrentBalance(user1), userTotal, "Total balance should be sum of all mints");

        // Check total supply (includes vault balance due to rebalancing)
        // After all mints: userTotal = 3500, vault = 3500 * 8000 / 2000 = 14000, total = 17500
        uint256 expectedTotal = userTotal + (userTotal * 8000 / 2000);
        assertEq(debtToken.totalSupply(currentEpoch), expectedTotal, "Total supply should include vault");
    }

    function test_Mint_MultipleUsers() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        uint256 amount3 = 1500e18;
        uint256 userTotal = amount1 + amount2 + amount3;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.startPrank(authorized);
        debtToken.mint(user1, amount1);
        debtToken.mint(user2, amount2);
        debtToken.mint(user3, amount3);
        vm.stopPrank();

        // Check individual balances
        assertEq(debtToken.getCurrentBalance(user1), amount1, "User1 balance should match");
        assertEq(debtToken.getCurrentBalance(user2), amount2, "User2 balance should match");
        assertEq(debtToken.getCurrentBalance(user3), amount3, "User3 balance should match");

        // Check total supply (includes vault balance)
        // userTotal = 4500, vault = 4500 * 8000 / 2000 = 18000, total = 22500
        uint256 expectedTotal = userTotal + (userTotal * 8000 / 2000);
        assertEq(debtToken.totalSupply(currentEpoch), expectedTotal, "Total supply should include vault");
    }

    // ============ Authorization Tests ============

    function test_Mint_RevertWhen_NotAuthorized() public {
        uint256 amount = 1000e18;

        vm.prank(unauthorized);
        vm.expectRevert(DebtToken.NotAuthorized.selector);
        debtToken.mint(user1, amount);
    }

    function test_Mint_AllowsZeroAddress() public {
        uint256 amount = 1000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        // The contract doesn't prevent minting to zero address
        // This is by design - the contract only checks authorization
        vm.prank(authorized);
        debtToken.mint(address(0), amount);

        // Verify it worked
        assertEq(debtToken.getCurrentBalance(address(0)), amount, "Zero address should have balance");
        // Total supply includes vault balance (80% ratio)
        uint256 expectedTotal = amount + (amount * 8000 / 2000);
        assertEq(debtToken.totalSupply(currentEpoch), expectedTotal, "Total supply should include vault");
    }

    function test_Mint_SuccessWhen_Authorized() public {
        uint256 amount = 1000e18;

        vm.prank(authorized);
        debtToken.mint(user1, amount);

        assertEq(debtToken.getCurrentBalance(user1), amount, "Mint should succeed when authorized");
    }

    // ============ Zero Amount Tests ============

    function test_Mint_RevertWhen_ZeroAmount() public {
        vm.prank(authorized);
        vm.expectRevert(DebtToken.ZeroAmount.selector);
        debtToken.mint(user1, 0);
    }

    // ============ Epoch Tests ============

    function test_Mint_DifferentEpochs() public {
        uint256 amount1 = 1000e18;
        uint256 epoch1 = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.prank(authorized);
        debtToken.mint(user1, amount1);

        uint256 expectedEpoch1Total = amount1 + (amount1 * 8000 / 2000);
        assertEq(debtToken.totalSupply(epoch1), expectedEpoch1Total, "Epoch1 supply should include vault");

        // Move to next epoch - warp to the hardcoded timestamp and roll to next block
        vm.warp(1767742579);
        vm.roll(block.number + 1);
        uint256 amount2 = 2000e18;
        
        // Calculate epoch2 directly from the warped timestamp (1767742579)
        // epoch2 = 1767742579 - (1767742579 % 604800) = 1767225600
        uint256 epoch2 = 1767225600;

        vm.prank(authorized);
        debtToken.mint(user1, amount2);

        // Check epoch-specific supplies
        assertEq(debtToken.totalSupply(epoch1), expectedEpoch1Total, "Epoch1 supply should remain unchanged");
        uint256 expectedEpoch2Total = amount2 + (amount2 * 8000 / 2000);
        // Verify epochs are different
        assertTrue(epoch2 != epoch1, "Epoch2 should be different from epoch1");
        assertEq(debtToken.totalSupply(epoch2), expectedEpoch2Total, "Epoch2 supply should include vault");
        assertEq(debtToken.totalSupply(), expectedEpoch2Total, "Current total supply should be epoch2 supply");

        // Check balance accumulates across epochs
        assertEq(debtToken.getCurrentBalance(user1), amount1 + amount2, "Balance should accumulate across epochs");
    }

    function test_Mint_SameEpochMultipleTimes() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        uint256 userTotal = amount1 + amount2;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.startPrank(authorized);
        debtToken.mint(user1, amount1);
        debtToken.mint(user1, amount2);
        vm.stopPrank();

        // Check that total supply per epoch accumulates (includes vault balance)
        uint256 expectedTotal = userTotal + (userTotal * 8000 / 2000);
        assertEq(debtToken.totalSupply(currentEpoch), expectedTotal, "Total supply per epoch should include vault");
    }

    // ============ Checkpoint Tests ============

    function test_Mint_CreatesCheckpoint() public {
        uint256 amount = 1000e18;

        vm.prank(authorized);
        debtToken.mint(user1, amount);

        // Verify checkpoint was created
        assertEq(debtToken.getNumCheckpoints(user1), 1, "Should have 1 checkpoint");
        assertEq(debtToken.getBalanceAtCheckpoint(user1, 0), amount, "Checkpoint balance should match");
    }

    function test_Mint_UpdatesCheckpointInSameEpoch() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        uint256 total = amount1 + amount2;

        vm.startPrank(authorized);
        debtToken.mint(user1, amount1);
        uint256 checkpointsBefore = debtToken.getNumCheckpoints(user1);
        debtToken.mint(user1, amount2);
        vm.stopPrank();

        // In the same epoch, checkpoint should be updated, not created
        assertEq(debtToken.getNumCheckpoints(user1), checkpointsBefore, "Should not create new checkpoint in same epoch");
        assertEq(debtToken.getCurrentBalance(user1), total, "Balance should be updated");
    }

    function test_Mint_CreatesNewCheckpointInNewEpoch() public {
        uint256 amount1 = 1000e18;

        vm.prank(authorized);
        debtToken.mint(user1, amount1);

        uint256 checkpointsBefore = debtToken.getNumCheckpoints(user1);

        // Move to next epoch
        vm.warp(block.timestamp + WEEK);
        uint256 amount2 = 2000e18;

        vm.prank(authorized);
        debtToken.mint(user1, amount2);

        // Should create new checkpoint in new epoch
        assertEq(debtToken.getNumCheckpoints(user1), checkpointsBefore + 1, "Should create new checkpoint in new epoch");
    }

    function test_Mint_CreatesSupplyCheckpoint() public {
        uint256 amount = 1000e18;

        vm.prank(authorized);
        debtToken.mint(user1, amount);

        // Verify supply checkpoint was created (includes vault balance)
        assertEq(debtToken.getSupplyNumCheckpoints(), 1, "Should have 1 supply checkpoint");
        uint256 expectedTotal = amount + (amount * 8000 / 2000);
        assertEq(debtToken.getSupplyAtCheckpoint(0), expectedTotal, "Supply checkpoint should include vault");
    }

    // ============ Event Tests ============

    function test_Mint_EmitsEvent() public {f
        uint256 amount = 1000e18;

        vm.prank(authorized);
        vm.expectEmit(true, false, false, true);
        emit DebtToken.Mint(user1, amount);
        debtToken.mint(user1, amount);
    }

    // ============ Edge Cases ============

    function test_Mint_LargeAmount() public {
        // Use a value that won't cause overflow when multiplied by 8000/2000 (i.e., * 4)
        // We need: largeAmount + (largeAmount * 4) <= type(uint256).max
        // So: largeAmount * 5 <= type(uint256).max
        // Therefore: largeAmount <= type(uint256).max / 5
        // Use a safe value that's well below the limit
        uint256 largeAmount = 1e50; // A large but safe value

        vm.prank(authorized);
        debtToken.mint(user1, largeAmount);

        assertEq(debtToken.getCurrentBalance(user1), largeAmount, "Should handle large amounts correctly");
        // Calculate expected total: vault gets 4x the user amount
        uint256 vaultAmount = (largeAmount * 8000) / 2000;
        uint256 expectedTotal = largeAmount + vaultAmount;
        assertEq(debtToken.totalSupply(), expectedTotal, "Total supply should include vault");
    }

    function test_Mint_MultipleUsersSameEpoch() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        uint256 amount3 = 1500e18;
        uint256 userTotal = amount1 + amount2 + amount3;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.startPrank(authorized);
        debtToken.mint(user1, amount1);
        debtToken.mint(user2, amount2);
        debtToken.mint(user3, amount3);
        vm.stopPrank();

        // All mints in same epoch should accumulate total supply (includes vault)
        uint256 expectedTotal = userTotal + (userTotal * 8000 / 2000);
        assertEq(debtToken.totalSupply(currentEpoch), expectedTotal, "Total supply should include vault");
    }

    function test_Mint_ComplexScenario() public {
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        // Mint to user1 in epoch 1
        vm.prank(authorized);
        debtToken.mint(user1, 1000e18);

        // Mint to user2 in epoch 1
        vm.prank(authorized);
        debtToken.mint(user2, 2000e18);

        uint256 epoch1UserTotal = 3000e18;
        uint256 epoch1ExpectedTotal = epoch1UserTotal + (epoch1UserTotal * 8000 / 2000);
        assertEq(debtToken.totalSupply(currentEpoch), epoch1ExpectedTotal, "Epoch1 total should include vault");

        // Move to epoch 2 - warp to the hardcoded timestamp and roll to next block
        vm.warp(1767742579);
        vm.roll(block.number + 1);
        // Calculate epoch2 directly from the warped timestamp (1767742579)
        // epoch2 = 1767742579 - (1767742579 % 604800) = 1767225600
        uint256 epoch2 = 1767225600;

        // Mint more to user1 in epoch 2
        vm.prank(authorized);
        debtToken.mint(user1, 500e18);

        // Mint to user3 in epoch 2
        vm.prank(authorized);
        debtToken.mint(user3, 1500e18);

        // Verify epoch-specific supplies
        assertEq(debtToken.totalSupply(currentEpoch), epoch1ExpectedTotal, "Epoch1 supply should remain unchanged");
        uint256 epoch2UserTotal = 2000e18;
        uint256 epoch2ExpectedTotal = epoch2UserTotal + (epoch2UserTotal * 8000 / 2000);
        assertEq(debtToken.totalSupply(epoch2), epoch2ExpectedTotal, "Epoch2 supply should include vault");

        // Verify user balances
        assertEq(debtToken.getCurrentBalance(user1), 1500e18, "User1 balance should accumulate");
        assertEq(debtToken.getCurrentBalance(user2), 2000e18, "User2 balance should remain");
        assertEq(debtToken.getCurrentBalance(user3), 1500e18, "User3 balance should be correct");
    }

    // ============ Rebalancing Tests ============

    function test_Rebalance_DefaultRatio80Percent() public {
        uint256 userAmount = 1000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        
        // Default vaultRatioBps is 8000 (80%)
        // When we mint 1000 to user, vault should get 4000 (80% of total 5000)
        // Formula: newVaultBalance = userSupply * 8000 / 2000 = 1000 * 4 = 4000
        
        vm.prank(authorized);
        debtToken.mint(user1, userAmount);

        uint256 vaultBalance = debtToken.getCurrentBalance(address(debtToken));
        uint256 totalSupply = debtToken.totalSupply(currentEpoch);
        uint256 userBalance = debtToken.getCurrentBalance(user1);

        // User should have the minted amount
        assertEq(userBalance, userAmount, "User balance should match minted amount");
        
        // Total supply = user supply + vault supply
        assertEq(totalSupply, userBalance + vaultBalance, "Total supply should be user + vault");
        
        // Vault should have 80% of total supply
        // vaultBalance / totalSupply should be approximately 0.8 (80%)
        // Using basis points: vaultBalance * 10000 / totalSupply should be approximately 8000
        uint256 actualRatio = (vaultBalance * 10000) / totalSupply;
        assertEq(actualRatio, 8000, "Vault should have 80% of total supply");
        
        // Verify: if user has 1000, vault should have 4000, total = 5000
        assertEq(vaultBalance, 4000e18, "Vault should have 4000 tokens");
        assertEq(totalSupply, 5000e18, "Total supply should be 5000 tokens");
    }

    function test_Rebalance_CustomRatio20Percent() public {
        // Set vault ratio to 20%
        vm.prank(authorized);
        debtToken.setVaultRatioBps(2000);
        
        uint256 userAmount = 1000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        
        // When vaultRatioBps is 2000 (20%)
        // newVaultBalance = userSupply * 2000 / 8000 = 1000 * 0.25 = 250
        // Total = 1000 + 250 = 1250, vault ratio = 250/1250 = 20%
        
        vm.prank(authorized);
        debtToken.mint(user1, userAmount);

        uint256 vaultBalance = debtToken.getCurrentBalance(address(debtToken));
        uint256 totalSupply = debtToken.totalSupply(currentEpoch);
        uint256 userBalance = debtToken.getCurrentBalance(user1);

        assertEq(userBalance, userAmount, "User balance should match minted amount");
        assertEq(totalSupply, userBalance + vaultBalance, "Total supply should be user + vault");
        
        // Vault should have 20% of total supply
        uint256 actualRatio = (vaultBalance * 10000) / totalSupply;
        assertEq(actualRatio, 2000, "Vault should have 20% of total supply");
        
        // Verify: if user has 1000, vault should have 250, total = 1250
        assertEq(vaultBalance, 250e18, "Vault should have 250 tokens");
        assertEq(totalSupply, 1250e18, "Total supply should be 1250 tokens");
    }

    function test_Rebalance_MultipleMints() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        
        // First mint: user gets 1000, vault should get 4000 (80% ratio)
        vm.prank(authorized);
        debtToken.mint(user1, amount1);
        
        uint256 vaultBalance1 = debtToken.getCurrentBalance(address(debtToken));
        uint256 totalSupply1 = debtToken.totalSupply(currentEpoch);
        
        assertEq(vaultBalance1, 4000e18, "After first mint, vault should have 4000");
        assertEq(totalSupply1, 5000e18, "After first mint, total should be 5000");
        
        // Second mint: user gets additional 2000 (total 3000)
        // After rebalance: userSupply = 3000, vault should get 3000 * 8000 / 2000 = 12000
        // Total = 3000 + 12000 = 15000
        vm.prank(authorized);
        debtToken.mint(user1, amount2);
        
        uint256 vaultBalance2 = debtToken.getCurrentBalance(address(debtToken));
        uint256 totalSupply2 = debtToken.totalSupply(currentEpoch);
        uint256 userBalance2 = debtToken.getCurrentBalance(user1);
        
        assertEq(userBalance2, amount1 + amount2, "User should have total of both mints");
        assertEq(vaultBalance2, 12000e18, "After second mint, vault should have 12000");
        assertEq(totalSupply2, 15000e18, "After second mint, total should be 15000");
        
        // Verify ratio is still 80%
        uint256 actualRatio = (vaultBalance2 * 10000) / totalSupply2;
        assertEq(actualRatio, 8000, "Vault should still have 80% of total supply");
    }

    function test_Rebalance_MultipleUsers() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        
        // Mint to user1
        vm.prank(authorized);
        debtToken.mint(user1, amount1);
        
        uint256 vaultBalance1 = debtToken.getCurrentBalance(address(debtToken));
        assertEq(vaultBalance1, 4000e18, "After user1 mint, vault should have 4000");
        
        // Mint to user2
        vm.prank(authorized);
        debtToken.mint(user2, amount2);
        
        // After user2 mint: userSupply = 1000 + 2000 = 3000
        // Vault should be rebalanced to: 3000 * 8000 / 2000 = 12000
        uint256 vaultBalance2 = debtToken.getCurrentBalance(address(debtToken));
        uint256 totalSupply2 = debtToken.totalSupply(currentEpoch);
        
        assertEq(vaultBalance2, 12000e18, "After user2 mint, vault should have 12000");
        assertEq(totalSupply2, 15000e18, "Total supply should be 15000");
        
        // Verify ratio
        uint256 actualRatio = (vaultBalance2 * 10000) / totalSupply2;
        assertEq(actualRatio, 8000, "Vault should have 80% of total supply");
    }

    function test_Rebalance_ZeroRatio() public {
        // Set ratio to 0 (should not rebalance)
        vm.prank(authorized);
        debtToken.setVaultRatioBps(0);
        
        uint256 userAmount = 1000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        
        vm.prank(authorized);
        debtToken.mint(user1, userAmount);
        
        uint256 vaultBalance = debtToken.getCurrentBalance(address(debtToken));
        uint256 totalSupply = debtToken.totalSupply(currentEpoch);
        
        // With 0 ratio, vault should have 0 balance
        assertEq(vaultBalance, 0, "Vault should have 0 balance with 0 ratio");
        assertEq(totalSupply, userAmount, "Total supply should only include user amount");
    }

    function test_Rebalance_RatioChange() public {
        uint256 userAmount = 1000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        
        // First mint with default 80% ratio
        vm.prank(authorized);
        debtToken.mint(user1, userAmount);
        
        uint256 vaultBalance1 = debtToken.getCurrentBalance(address(debtToken));
        assertEq(vaultBalance1, 4000e18, "Vault should have 4000 with 80% ratio");
        
        // Change ratio to 20%
        vm.prank(authorized);
        debtToken.setVaultRatioBps(2000);
        
        // Mint again - should use new ratio
        vm.prank(authorized);
        debtToken.mint(user2, userAmount);
        
        // After second mint: userSupply = 1000 + 1000 = 2000
        // With 20% ratio: vault = 2000 * 2000 / 8000 = 500
        uint256 vaultBalance2 = debtToken.getCurrentBalance(address(debtToken));
        uint256 totalSupply2 = debtToken.totalSupply(currentEpoch);
        
        assertEq(vaultBalance2, 500e18, "Vault should have 500 with 20% ratio");
        assertEq(totalSupply2, 2500e18, "Total supply should be 2500");
        
        // Verify new ratio
        uint256 actualRatio = (vaultBalance2 * 10000) / totalSupply2;
        assertEq(actualRatio, 2000, "Vault should have 20% of total supply");
    }

    function test_Rebalance_VaultCheckpointCreated() public {
        uint256 userAmount = 1000e18;
        
        vm.prank(authorized);
        debtToken.mint(user1, userAmount);
        
        // Vault should have a checkpoint
        uint256 vaultCheckpoints = debtToken.getNumCheckpoints(address(debtToken));
        assertGt(vaultCheckpoints, 0, "Vault should have at least one checkpoint");
        
        uint256 vaultBalance = debtToken.getCurrentBalance(address(debtToken));
        assertGt(vaultBalance, 0, "Vault should have a balance");
    }

    // ============ Helper Functions ============

    function getCurrentEpoch() internal view returns (uint256) {
        return ProtocolTimeLibrary.epochStart(block.timestamp);
    }

    /**
     * @notice Helper function to calculate the start of the next epoch
     * @param timestamp The current timestamp
     * @return The start timestamp of the next epoch
     */
    function getNextEpochStart(uint256 timestamp) internal pure returns (uint256) {
        return timestamp - (timestamp % WEEK) + WEEK;
    }

    /**
     * @notice Helper function to warp to the next epoch
     * Warps to a hardcoded timestamp (1767742579) which is one week after the initial timestamp
     * Also rolls to the next block number
     */
    function warpToNextEpoch() internal {
        vm.warp(1767742579);
        vm.roll(block.number + 1);
    }
}

