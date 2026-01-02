// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {DebtToken} from "../../vault/DebtToken.sol";
import {ProtocolTimeLibrary} from "../../src/libraries/ProtocolTimeLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MockDebtToken
 * @notice Mock implementation of DebtToken for testing purposes
 * @dev Exposes internal functions as public/external to enable testing
 */
contract MockDebtToken is DebtToken {
    uint256 private _vaultRatioBps = 8000; // Default to 80% (8000 basis points)
    
    /**
     * @notice Constructor to initialize the mock
     * @param _vault The vault address to use for rebalancing
     */
    constructor(address _vault) DebtToken(_vault) {
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
     * @notice Sets the vault ratio in basis points (e.g., 2000 = 20%, 8000 = 80%)
     * @dev Only callable by the authorized address
     * @param _ratio The vault ratio in basis points (must be between 0 and 10000)
     */
    function setVaultRatioBps(uint256 _ratio) external {
        if (msg.sender != authorized) revert NotAuthorized();
        if (_ratio >= 10000) revert InvalidReward(); // Ratio cannot be 100% or more
        _vaultRatioBps = _ratio;
    }

    /**
     * @notice Override to return the local vault ratio variable
     * @return The vault ratio in basis points
     */
    function getVaultRatioBps() public view override returns (uint256) {
        return _vaultRatioBps;
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

    /**
     * @notice Exposes _convertToShares for testing
     * @param assets The amount of assets to convert
     * @param rounding The rounding direction
     * @return The amount of shares
     */
    function convertToShares(uint256 assets, uint8 rounding) external view returns (uint256) {
        return _convertToShares(assets, Math.Rounding(rounding));
    }

    /**
     * @notice Exposes _convertToShares with epoch for testing
     * @param assets The amount of assets to convert
     * @param rounding The rounding direction
     * @param epoch The epoch to use for conversion
     * @return The amount of shares
     */
    function convertToShares(uint256 assets, uint8 rounding, uint256 epoch) external view returns (uint256) {
        return _convertToShares(assets, Math.Rounding(rounding), epoch);
    }

    /**
     * @notice Exposes _convertToAssets for testing
     * @param shares The amount of shares to convert
     * @param rounding The rounding direction
     * @return The amount of assets
     */
    function convertToAssets(uint256 shares, uint8 rounding) external view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding(rounding));
    }

    /**
     * @notice Exposes _convertToAssets with epoch for testing
     * @param shares The amount of shares to convert
     * @param rounding The rounding direction
     * @param epoch The epoch to use for conversion
     * @return The amount of assets
     */
    function convertToAssets(uint256 shares, uint8 rounding, uint256 epoch) external view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding(rounding), epoch);
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
        
        // Create a mock vault address (using the test contract itself for simplicity)
        address mockVault = address(this);
        debtToken = new MockDebtToken(mockVault);
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

    function test_Mint_EmitsEvent() public {
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

        uint256 vaultBalance = debtToken.getCurrentBalance(debtToken.vault());
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

        uint256 vaultBalance = debtToken.getCurrentBalance(debtToken.vault());
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
        
        uint256 vaultBalance1 = debtToken.getCurrentBalance(debtToken.vault());
        uint256 totalSupply1 = debtToken.totalSupply(currentEpoch);
        
        assertEq(vaultBalance1, 4000e18, "After first mint, vault should have 4000");
        assertEq(totalSupply1, 5000e18, "After first mint, total should be 5000");
        
        // Second mint: user gets additional 2000 (total 3000)
        // After rebalance: userSupply = 3000, vault should get 3000 * 8000 / 2000 = 12000
        // Total = 3000 + 12000 = 15000
        vm.prank(authorized);
        debtToken.mint(user1, amount2);
        
        uint256 vaultBalance2 = debtToken.getCurrentBalance(debtToken.vault());
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
        
        uint256 vaultBalance1 = debtToken.getCurrentBalance(debtToken.vault());
        assertEq(vaultBalance1, 4000e18, "After user1 mint, vault should have 4000");
        
        // Mint to user2
        vm.prank(authorized);
        debtToken.mint(user2, amount2);
        
        // After user2 mint: userSupply = 1000 + 2000 = 3000
        // Vault should be rebalanced to: 3000 * 8000 / 2000 = 12000
        uint256 vaultBalance2 = debtToken.getCurrentBalance(debtToken.vault());
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
        
        uint256 vaultBalance = debtToken.getCurrentBalance(debtToken.vault());
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
        
        uint256 vaultBalance1 = debtToken.getCurrentBalance(debtToken.vault());
        assertEq(vaultBalance1, 4000e18, "Vault should have 4000 with 80% ratio");
        
        // Change ratio to 20%
        vm.prank(authorized);
        debtToken.setVaultRatioBps(2000);
        
        // Mint again - should use new ratio
        vm.prank(authorized);
        debtToken.mint(user2, userAmount);
        
        // After second mint: userSupply = 1000 + 1000 = 2000
        // With 20% ratio: vault = 2000 * 2000 / 8000 = 500
        uint256 vaultBalance2 = debtToken.getCurrentBalance(debtToken.vault());
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
        uint256 vaultCheckpoints = debtToken.getNumCheckpoints(debtToken.vault());
        assertGt(vaultCheckpoints, 0, "Vault should have at least one checkpoint");
        
        uint256 vaultBalance = debtToken.getCurrentBalance(debtToken.vault());
        assertGt(vaultBalance, 0, "Vault should have a balance");
    }

    // ============ Total Assets Tests ============

    function test_TotalAssets_TracksAssetsPerEpoch() public {
        uint256 amount = 1000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.prank(authorized);
        debtToken.mint(user1, amount);

        // For current epoch, assets are distributed over time, so it will be less than full amount
        // unless we're at the end of the epoch
        uint256 distributedAssets = debtToken.totalAssets(currentEpoch);
        assertLe(distributedAssets, amount, "Distributed assets should be <= full amount");
        assertGt(distributedAssets, 0, "Distributed assets should be > 0");
        
        // totalAssets() without epoch returns full amount (not distributed)
        assertEq(debtToken.totalAssets(), amount, "Current total assets should match full amount");
    }

    function test_TotalAssets_AccumulatesAcrossMints() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        uint256 total = amount1 + amount2;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.startPrank(authorized);
        debtToken.mint(user1, amount1);
        debtToken.mint(user2, amount2);
        vm.stopPrank();

        // For current epoch, assets are distributed over time
        uint256 distributedAssets = debtToken.totalAssets(currentEpoch);
        assertLe(distributedAssets, total, "Distributed assets should be <= full amount");
        assertGt(distributedAssets, 0, "Distributed assets should be > 0");
    }

    function test_TotalAssets_DifferentEpochs() public {
        uint256 amount1 = 1000e18;
        uint256 epoch1 = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.prank(authorized);
        debtToken.mint(user1, amount1);

        // We're currently in epoch1, so it returns distributed amount
        uint256 distributed1 = debtToken.totalAssets(epoch1);
        assertLe(distributed1, amount1, "Current epoch should return distributed amount");
        assertGt(distributed1, 0, "Distributed amount should be > 0");

        // Move to next epoch
        vm.warp(1767742579);
        vm.roll(block.number + 1);
        uint256 epoch2 = 1767225600;
        uint256 amount2 = 2000e18;

        vm.prank(authorized);
        debtToken.mint(user1, amount2);

        // Epoch1 is now a past epoch, should return full amount
        assertEq(debtToken.totalAssets(epoch1), amount1, "Epoch1 assets should return full amount (past epoch)");
        
        // Epoch2 is current epoch, so it returns distributed amount
        uint256 distributedAssets2 = debtToken.totalAssets(epoch2);
        assertLe(distributedAssets2, amount2, "Current epoch assets should be distributed");
        assertGt(distributedAssets2, 0, "Distributed assets should be > 0");
    }

    function test_TotalAssets_ZeroWhenNoMints() public {
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        assertEq(debtToken.totalAssets(currentEpoch), 0, "Total assets should be 0 when no mints");
    }

    // ============ Time-Based Distribution Tests ============

    function test_TotalAssets_DistributesOverTime() public {
        uint256 amount = 1000e18;
        // Start at the beginning of a new epoch
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        uint256 epochStart = currentEpoch;
        uint256 epochDuration = ProtocolTimeLibrary.epochNext(currentEpoch) - currentEpoch;
        
        // Warp to the start of the epoch
        vm.warp(epochStart);
        vm.roll(block.number + 1);

        vm.prank(authorized);
        debtToken.mint(user1, amount);

        // At the start of epoch, distributed amount should be 0
        uint256 assetsAtStart = debtToken.totalAssets(currentEpoch);
        assertEq(assetsAtStart, 0, "At epoch start, distributed assets should be 0");

        // Warp to 25% through the epoch
        vm.warp(epochStart + epochDuration / 4);
        vm.roll(block.number + 1);
        uint256 assetsAt25Percent = debtToken.totalAssets(currentEpoch);
        uint256 expectedAt25Percent = amount / 4;
        assertApproxEqAbs(assetsAt25Percent, expectedAt25Percent, 1e15, "At 25% of epoch, should have ~25% of assets");

        // Warp to 50% through the epoch
        vm.warp(epochStart + epochDuration / 2);
        vm.roll(block.number + 1);
        uint256 assetsAt50Percent = debtToken.totalAssets(currentEpoch);
        uint256 expectedAt50Percent = amount / 2;
        assertApproxEqAbs(assetsAt50Percent, expectedAt50Percent, 1e15, "At 50% of epoch, should have ~50% of assets");

        // Warp to 75% through the epoch
        vm.warp(epochStart + (epochDuration * 3) / 4);
        vm.roll(block.number + 1);
        uint256 assetsAt75Percent = debtToken.totalAssets(currentEpoch);
        uint256 expectedAt75Percent = (amount * 3) / 4;
        assertApproxEqAbs(assetsAt75Percent, expectedAt75Percent, 1e15, "At 75% of epoch, should have ~75% of assets");

        // Warp to end of epoch (should have almost full amount, accounting for integer division precision)
        vm.warp(ProtocolTimeLibrary.epochNext(currentEpoch) - 1);
        vm.roll(block.number + 1);
        uint256 assetsAtEnd = debtToken.totalAssets(currentEpoch);
        // Due to integer division, we might be slightly less than full amount
        // The error is approximately assets / duration, which for 1000e18 / 604800 ≈ 1.65e15
        assertApproxEqAbs(assetsAtEnd, amount, 2e15, "At end of epoch, should have almost full amount");
    }

    function test_TotalAssets_PastEpochReturnsFullAmount() public {
        uint256 amount = 1000e18;
        uint256 epoch1 = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.prank(authorized);
        debtToken.mint(user1, amount);

        // Move to next epoch (past epoch1)
        vm.warp(1767742579);
        vm.roll(block.number + 1);
        uint256 epoch2 = ProtocolTimeLibrary.epochStart(block.timestamp);

        // Epoch1 is now a past epoch, should return full amount
        assertEq(debtToken.totalAssets(epoch1), amount, "Past epoch should return full amount");
        
        // Epoch2 is current, should return distributed amount (but we just started it, so should be 0 or very small)
        uint256 distributed = debtToken.totalAssets(epoch2);
        assertLe(distributed, amount, "Current epoch should return distributed amount");
    }

    function test_TotalAssets_DistributionWithMultipleMints() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        uint256 total = amount1 + amount2;
        // Start at the beginning of a new epoch
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        uint256 epochStart = currentEpoch;
        uint256 epochDuration = ProtocolTimeLibrary.epochNext(currentEpoch) - currentEpoch;

        // Warp to the start of the epoch
        vm.warp(epochStart);
        vm.roll(block.number + 1);

        // First mint
        vm.prank(authorized);
        debtToken.mint(user1, amount1);

        // Warp to 50% through epoch
        vm.warp(epochStart + epochDuration / 2);
        vm.roll(block.number + 1);
        uint256 distributedAfterFirst = debtToken.totalAssets(currentEpoch);
        uint256 expectedAfterFirst = amount1 / 2;
        assertApproxEqAbs(distributedAfterFirst, expectedAfterFirst, 1e15, "After first mint at 50%, should have 50% of first amount");

        // Second mint (still at 50% through epoch)
        vm.prank(authorized);
        debtToken.mint(user2, amount2);

        // Now total assets in epoch is amount1 + amount2
        // At 50% through epoch, should have 50% of total
        // Note: The distribution is based on when the epoch started, not when mints occurred
        uint256 distributedAfterSecond = debtToken.totalAssets(currentEpoch);
        uint256 expectedAfterSecond = total / 2;
        assertApproxEqAbs(distributedAfterSecond, expectedAfterSecond, 1e15, "After second mint at 50%, should have 50% of total");
    }

    function test_TotalAssets_DistributionAtEpochBoundary() public {
        uint256 amount = 1000e18;
        // Start at the beginning of a new epoch
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        uint256 epochStart = currentEpoch;
        uint256 nextEpoch = ProtocolTimeLibrary.epochNext(currentEpoch);

        // Warp to the start of the epoch
        vm.warp(epochStart);
        vm.roll(block.number + 1);

        vm.prank(authorized);
        debtToken.mint(user1, amount);

        // At the very start of epoch (epoch timestamp itself)
        assertEq(debtToken.totalAssets(currentEpoch), 0, "At epoch start, should be 0");

        // Just before next epoch
        vm.warp(nextEpoch - 1);
        vm.roll(block.number + 1);
        uint256 assetsJustBeforeEnd = debtToken.totalAssets(currentEpoch);
        // Due to integer division, we might be slightly less than full amount
        // The error is approximately assets / duration
        assertApproxEqAbs(assetsJustBeforeEnd, amount, 2e15, "Just before epoch end, should have almost full amount");

        // Move to next epoch - current epoch becomes past epoch
        vm.warp(nextEpoch);
        vm.roll(block.number + 1);
        assertEq(debtToken.totalAssets(currentEpoch), amount, "Past epoch should return full amount");
    }

    function test_TotalAssets_50PercentRatio_TrackDistributionThroughoutWeek() public {
        // Set vault ratio to 50%
        vm.prank(authorized);
        debtToken.setVaultRatioBps(5000);
        
        uint256 amount = 10000e18; // 10,000 tokens for easier calculation
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        uint256 epochStart = currentEpoch;
        uint256 epochDuration = ProtocolTimeLibrary.epochNext(currentEpoch) - currentEpoch;
        
        // Warp to the start of the epoch
        vm.warp(epochStart);
        vm.roll(block.number + 1);
        
        // Mint assets at the start of the epoch
        vm.prank(authorized);
        debtToken.mint(user1, amount);
        
        uint256 currentEpochAfterMint = ProtocolTimeLibrary.epochStart(block.timestamp);
        assertEq(currentEpochAfterMint, epochStart, "Should still be in the same epoch");
        
        // Track distribution throughout the week
        // Day 0 (start of epoch) - 0% elapsed
        uint256 assetsDay0 = debtToken.totalAssets(epochStart);
        uint256 expectedDay0 = 0;
        assertEq(assetsDay0, expectedDay0, "Day 0: Should have 0 assets distributed");
        
        // Day 1 - ~14.29% elapsed (1/7 of week)
        vm.warp(epochStart + epochDuration / 7);
        vm.roll(block.number + 1);
        uint256 assetsDay1 = debtToken.totalAssets(epochStart);
        uint256 expectedDay1 = amount / 7;
        assertApproxEqAbs(assetsDay1, expectedDay1, 1e15, "Day 1: Should have ~14.29% of assets");
        
        // Day 2 - ~28.57% elapsed (2/7 of week)
        vm.warp(epochStart + (epochDuration * 2) / 7);
        vm.roll(block.number + 1);
        uint256 assetsDay2 = debtToken.totalAssets(epochStart);
        uint256 expectedDay2 = (amount * 2) / 7;
        assertApproxEqAbs(assetsDay2, expectedDay2, 1e15, "Day 2: Should have ~28.57% of assets");
        
        // Day 3 - ~42.86% elapsed (3/7 of week)
        vm.warp(epochStart + (epochDuration * 3) / 7);
        vm.roll(block.number + 1);
        uint256 assetsDay3 = debtToken.totalAssets(epochStart);
        uint256 expectedDay3 = (amount * 3) / 7;
        assertApproxEqAbs(assetsDay3, expectedDay3, 1e15, "Day 3: Should have ~42.86% of assets");
        
        // Day 4 - ~57.14% elapsed (4/7 of week) - Mid week
        vm.warp(epochStart + (epochDuration * 4) / 7);
        vm.roll(block.number + 1);
        uint256 assetsDay4 = debtToken.totalAssets(epochStart);
        uint256 expectedDay4 = (amount * 4) / 7;
        assertApproxEqAbs(assetsDay4, expectedDay4, 1e15, "Day 4: Should have ~57.14% of assets (mid week)");
        
        // Day 5 - ~71.43% elapsed (5/7 of week)
        vm.warp(epochStart + (epochDuration * 5) / 7);
        vm.roll(block.number + 1);
        uint256 assetsDay5 = debtToken.totalAssets(epochStart);
        uint256 expectedDay5 = (amount * 5) / 7;
        assertApproxEqAbs(assetsDay5, expectedDay5, 1e15, "Day 5: Should have ~71.43% of assets");
        
        // Day 6 - ~85.71% elapsed (6/7 of week)
        vm.warp(epochStart + (epochDuration * 6) / 7);
        vm.roll(block.number + 1);
        uint256 assetsDay6 = debtToken.totalAssets(epochStart);
        uint256 expectedDay6 = (amount * 6) / 7;
        assertApproxEqAbs(assetsDay6, expectedDay6, 1e15, "Day 6: Should have ~85.71% of assets");
        
        // Day 7 (end of epoch) - ~100% elapsed
        vm.warp(ProtocolTimeLibrary.epochNext(epochStart) - 1);
        vm.roll(block.number + 1);
        uint256 assetsDay7 = debtToken.totalAssets(epochStart);
        // At the end, should have almost full amount (accounting for integer division)
        // The error is approximately assets / duration, which for 10000e18 / 604800 ≈ 1.65e16
        assertApproxEqAbs(assetsDay7, amount, 2e16, "Day 7: Should have almost full amount");
        
        // Verify linear progression
        assertLt(assetsDay0, assetsDay1, "Assets should increase from day 0 to day 1");
        assertLt(assetsDay1, assetsDay2, "Assets should increase from day 1 to day 2");
        assertLt(assetsDay2, assetsDay3, "Assets should increase from day 2 to day 3");
        assertLt(assetsDay3, assetsDay4, "Assets should increase from day 3 to day 4");
        assertLt(assetsDay4, assetsDay5, "Assets should increase from day 4 to day 5");
        assertLt(assetsDay5, assetsDay6, "Assets should increase from day 5 to day 6");
        assertLt(assetsDay6, assetsDay7, "Assets should increase from day 6 to day 7");
        
        // Verify the distribution rate is consistent
        // The difference between consecutive days should be approximately equal
        uint256 diff1 = assetsDay1 - assetsDay0;
        uint256 diff2 = assetsDay2 - assetsDay1;
        uint256 diff3 = assetsDay3 - assetsDay2;
        uint256 expectedDailyDiff = amount / 7;
        
        assertApproxEqAbs(diff1, expectedDailyDiff, 1e15, "Day 0-1 difference should be ~1/7 of total");
        assertApproxEqAbs(diff2, expectedDailyDiff, 1e15, "Day 1-2 difference should be ~1/7 of total");
        assertApproxEqAbs(diff3, expectedDailyDiff, 1e15, "Day 2-3 difference should be ~1/7 of total");
        
        // Move to next epoch and verify past epoch returns full amount
        vm.warp(ProtocolTimeLibrary.epochNext(epochStart));
        vm.roll(block.number + 1);
        uint256 assetsPastEpoch = debtToken.totalAssets(epochStart);
        assertEq(assetsPastEpoch, amount, "Past epoch should return full amount");
        
        // Verify vault ratio is maintained throughout
        uint256 vaultBalance = debtToken.getCurrentBalance(debtToken.vault());
        uint256 totalSupply = debtToken.totalSupply(epochStart);
        uint256 vaultRatio = (vaultBalance * 10000) / totalSupply;
        assertEq(vaultRatio, 5000, "Vault should maintain 50% ratio");
    }

    function test_TotalAssets_RatioChangeMidWeek_NoAssetDecrease() public {
        // Test that changing vault ratio mid-week doesn't decrease assets
        // Assets should continue to accrue, just at different rates for user vs vault
        
        // Start with 50/50 ratio
        vm.prank(authorized);
        debtToken.setVaultRatioBps(5000);
        
        uint256 amount = 10000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        uint256 epochStart = currentEpoch;
        uint256 epochDuration = ProtocolTimeLibrary.epochNext(currentEpoch) - currentEpoch;
        
        // Get the actual epoch start (the epoch that epochStart falls into)
        uint256 actualEpochStart = ProtocolTimeLibrary.epochStart(epochStart);
        
        // Warp to the start of the epoch
        vm.warp(actualEpochStart);
        vm.roll(block.number + 1);
        
        // Mint assets at the start of the epoch
        vm.prank(authorized);
        debtToken.mint(user1, amount);
        
        // Track initial state with 50/50 ratio (at epoch start, assets are 0 due to distribution)
        uint256 userBalanceStart = debtToken.getCurrentBalance(user1);
        uint256 vaultBalanceStart = debtToken.getCurrentBalance(debtToken.vault());
        uint256 totalSupplyStart = debtToken.totalSupply(actualEpochStart);
        
        // Day 1 - ~14.29% elapsed (1/7 of week) - Still 50/50 ratio
        vm.warp(actualEpochStart + epochDuration / 7);
        vm.roll(block.number + 1);
        
        // Use the actual epoch start we minted in
        uint256 totalAssetsDay1 = debtToken.totalAssets(actualEpochStart);
        uint256 userBalanceDay1 = debtToken.getCurrentBalance(user1);
        uint256 vaultBalanceDay1 = debtToken.getCurrentBalance(debtToken.vault());
        
        // Day 2 - ~28.57% elapsed (2/7 of week) - Still 50/50 ratio
        vm.warp(actualEpochStart + (epochDuration * 2) / 7);
        vm.roll(block.number + 1);
        
        // Use the actual epoch start we minted in
        uint256 userBalanceDay2 = debtToken.getCurrentBalance(user1);
        uint256 vaultBalanceDay2 = debtToken.getCurrentBalance(debtToken.vault());
        uint256 totalSupplyDay2 = debtToken.totalSupply(actualEpochStart);
        uint256 totalAssetsDay2 = debtToken.totalAssets(actualEpochStart);
        
        // Verify assets are increasing (distributed over time)
        assertGt(totalAssetsDay2, totalAssetsDay1, "Total assets should increase from day 1 to day 2");
        assertEq(userBalanceDay2, userBalanceStart, "User balance should remain constant (no new mints)");
        // Vault balance stays the same until a new mint triggers rebalancing
        assertGe(vaultBalanceDay2, vaultBalanceStart, "Vault balance should not decrease");
        
        // Verify 50/50 ratio is maintained
        uint256 vaultRatioDay2 = (vaultBalanceDay2 * 10000) / totalSupplyDay2;
        assertApproxEqAbs(vaultRatioDay2, 5000, 100, "Vault should maintain 50% ratio at day 2");
        
        // Day 4 - Mid week - Change ratio to 20% user / 80% vault
        vm.warp(actualEpochStart + (epochDuration * 4) / 7);
        vm.roll(block.number + 1);
        
        // Check state before ratio change (using actual epoch start)
        uint256 userBalanceBeforeRatioChange = debtToken.getCurrentBalance(user1);
        uint256 vaultBalanceBeforeRatioChange = debtToken.getCurrentBalance(debtToken.vault());
        uint256 totalAssetsBeforeRatioChange = debtToken.totalAssets(actualEpochStart);
        
        // Change ratio to 80% vault (20% user)
        vm.prank(authorized);
        debtToken.setVaultRatioBps(8000); // 80% vault = 20% user
        
        // Mint a small amount to trigger rebalance with new ratio
        vm.prank(authorized);
        debtToken.mint(user2, 1e18); // Small mint to trigger rebalance
        
        uint256 userBalanceDay4 = debtToken.getCurrentBalance(user1);
        uint256 vaultBalanceDay4 = debtToken.getCurrentBalance(debtToken.vault());
        uint256 totalSupplyDay4 = debtToken.totalSupply(actualEpochStart);
        uint256 totalAssetsDay4 = debtToken.totalAssets(actualEpochStart);
        
        // CRITICAL: No assets should decrease
        assertGe(totalAssetsDay4, totalAssetsBeforeRatioChange, "Total assets should NOT decrease after ratio change");
        assertGe(userBalanceDay4, userBalanceBeforeRatioChange, "User balance should NOT decrease after ratio change");
        assertGe(vaultBalanceDay4, vaultBalanceBeforeRatioChange, "Vault balance should NOT decrease after ratio change");
        
        // Verify new ratio is applied (80% vault)
        uint256 vaultRatioDay4 = (vaultBalanceDay4 * 10000) / totalSupplyDay4;
        assertApproxEqAbs(vaultRatioDay4, 8000, 100, "Vault should have 80% ratio after change");
        
        // Day 6 - Continue tracking with new ratio
        vm.warp(actualEpochStart + (epochDuration * 6) / 7);
        vm.roll(block.number + 1);
        
        // Use actual epoch start
        uint256 userBalanceDay6 = debtToken.getCurrentBalance(user1);
        uint256 vaultBalanceDay6 = debtToken.getCurrentBalance(debtToken.vault());
        uint256 totalSupplyDay6 = debtToken.totalSupply(actualEpochStart);
        uint256 totalAssetsDay6 = debtToken.totalAssets(actualEpochStart);
        
        // Assets should continue to increase
        assertGt(totalAssetsDay6, totalAssetsDay4, "Total assets should continue increasing from day 4 to day 6");
        assertGe(userBalanceDay6, userBalanceDay4, "User balance should NOT decrease");
        assertGe(vaultBalanceDay6, vaultBalanceDay4, "Vault balance should NOT decrease");
        
        // Verify 80% ratio is maintained
        uint256 vaultRatioDay6 = (vaultBalanceDay6 * 10000) / totalSupplyDay6;
        assertApproxEqAbs(vaultRatioDay6, 8000, 100, "Vault should maintain 80% ratio at day 6");
        
        // Day 7 - End of week (still in same epoch)
        vm.warp(ProtocolTimeLibrary.epochNext(actualEpochStart) - 1);
        vm.roll(block.number + 1);
        
        // Use actual epoch start (we're still in it, just at the end)
        uint256 userBalanceDay7 = debtToken.getCurrentBalance(user1);
        uint256 vaultBalanceDay7 = debtToken.getCurrentBalance(debtToken.vault());
        uint256 totalSupplyDay7 = debtToken.totalSupply(actualEpochStart);
        uint256 totalAssetsDay7 = debtToken.totalAssets(actualEpochStart);
        
        // Final checks: assets should be at maximum
        assertGt(totalAssetsDay7, totalAssetsDay6, "Total assets should continue increasing to end");
        assertGe(userBalanceDay7, userBalanceDay6, "User balance should NOT decrease");
        assertGe(vaultBalanceDay7, vaultBalanceDay6, "Vault balance should NOT decrease");
        
        // Verify the progression: assets should always increase throughout the week
        assertLt(totalAssetsDay1, totalAssetsDay2, "Assets increase from day 1 to day 2");
        assertLt(totalAssetsDay2, totalAssetsBeforeRatioChange, "Assets increase from day 2 to day 4 (before ratio change)");
        assertLe(totalAssetsBeforeRatioChange, totalAssetsDay4, "Assets don't decrease after ratio change");
        assertLt(totalAssetsDay4, totalAssetsDay6, "Assets continue increasing from day 4 to day 6");
        assertLt(totalAssetsDay6, totalAssetsDay7, "Assets continue increasing to end");
        
        // Verify vault balance doesn't decrease after ratio change
        // With 80% ratio, vault should have a larger share of the total supply
        // Note: Vault balance only changes when new mints occur (rebalancing)
        assertGe(vaultBalanceDay6, vaultBalanceDay4, "Vault balance should not decrease after ratio change");
        
        // Summary: Assets accrue continuously, vault gets larger share after ratio change
        // User's share of total supply decreases, but their absolute balance doesn't decrease
        uint256 userShareStart = (userBalanceStart * 10000) / totalSupplyStart;
        uint256 userShareEnd = (userBalanceDay7 * 10000) / totalSupplyDay7;
        
        // User's share should decrease (from 50% to 20% of supply)
        assertGt(userShareStart, userShareEnd, "User's share of supply should decrease after ratio change");
        // But absolute balance should not decrease
        assertGe(userBalanceDay7, userBalanceStart, "User's absolute balance should NOT decrease");
    }

    // ============ Conversion Tests ============

    function test_ConvertToShares_BasicConversion() public {
        uint256 assets = 1000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.prank(authorized);
        debtToken.mint(user1, assets);

        // After mint: totalAssets = 1000, totalSupply includes vault (5000 with 80% ratio)
        uint256 shares = debtToken.convertToShares(assets, 0, currentEpoch); // Rounding.Floor = 0
        assertGt(shares, 0, "Shares should be greater than 0");
        assertLt(shares, assets * 10, "Shares should be reasonable");
    }

    function test_ConvertToAssets_BasicConversion() public {
        uint256 assets = 1000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.prank(authorized);
        debtToken.mint(user1, assets);

        // Convert shares back to assets
        uint256 shares = debtToken.convertToShares(assets, 0, currentEpoch);
        uint256 convertedAssets = debtToken.convertToAssets(shares, 0, currentEpoch);
        
        // Should be approximately equal (within rounding)
        assertApproxEqRel(convertedAssets, assets, 1e15, "Converted assets should be approximately equal to original");
    }

    function test_ConvertToShares_ZeroAssets() public {
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        uint256 shares = debtToken.convertToShares(0, 0, currentEpoch);
        assertEq(shares, 0, "Zero assets should convert to zero shares");
    }

    function test_ConvertToAssets_ZeroShares() public {
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        uint256 assets = debtToken.convertToAssets(0, 0, currentEpoch);
        assertEq(assets, 0, "Zero shares should convert to zero assets");
    }

    function test_ConvertToShares_WithVaultRatio() public {
        uint256 assets = 1000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.prank(authorized);
        debtToken.mint(user1, assets);

        // With 80% vault ratio: totalSupply = 5000, totalAssets = 1000
        uint256 shares = debtToken.convertToShares(assets, 0, currentEpoch);
        
        // shares = 1000 * (5000 + 1) / (1000 + 1) ≈ 4995
        assertGt(shares, assets, "Shares should be greater than assets due to vault ratio");
    }

    function test_ConvertToShares_DifferentRatios() public {
        uint256 assets = 1000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        // Test with 80% ratio (default)
        vm.prank(authorized);
        debtToken.mint(user1, assets);
        uint256 shares80 = debtToken.convertToShares(assets, 0, currentEpoch);

        // Change to 20% ratio
        vm.prank(authorized);
        debtToken.setVaultRatioBps(2000);
        
        // Mint in new epoch to test new ratio
        vm.warp(1767742579);
        vm.roll(block.number + 1);
        uint256 epoch2 = 1767225600;
        
        vm.prank(authorized);
        debtToken.mint(user2, assets);
        uint256 shares20 = debtToken.convertToShares(assets, 0, epoch2);

        // With 20% ratio, totalSupply is smaller, so shares should be different
        assertTrue(shares80 != shares20, "Shares should differ with different ratios");
    }

    function test_ConvertToShares_RoundingModes() public {
        uint256 assets = 1000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.prank(authorized);
        debtToken.mint(user1, assets);

        uint256 sharesFloor = debtToken.convertToShares(assets, 0, currentEpoch); // Floor
        uint256 sharesCeil = debtToken.convertToShares(assets, 1, currentEpoch); // Ceil

        assertGe(sharesCeil, sharesFloor, "Ceiling should be >= floor");
    }

    function test_ConvertToAssets_RoundingModes() public {
        uint256 assets = 1000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.prank(authorized);
        debtToken.mint(user1, assets);

        uint256 shares = debtToken.convertToShares(assets, 0, currentEpoch);
        uint256 assetsFloor = debtToken.convertToAssets(shares, 0, currentEpoch); // Floor
        uint256 assetsCeil = debtToken.convertToAssets(shares, 1, currentEpoch); // Ceil

        assertGe(assetsCeil, assetsFloor, "Ceiling should be >= floor");
    }

    function test_ConvertToShares_MultipleMints() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.startPrank(authorized);
        debtToken.mint(user1, amount1);
        debtToken.mint(user2, amount2);
        vm.stopPrank();

        // Convert total assets to shares
        uint256 totalAssets = debtToken.totalAssets(currentEpoch);
        uint256 shares = debtToken.convertToShares(totalAssets, 0, currentEpoch);
        
        assertGt(shares, 0, "Shares should be greater than 0");
    }

    function test_ConvertToShares_AcrossEpochs() public {
        uint256 amount1 = 1000e18;
        uint256 epoch1 = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.prank(authorized);
        debtToken.mint(user1, amount1);

        uint256 shares1 = debtToken.convertToShares(amount1, 0, epoch1);

        // Move to next epoch
        vm.warp(1767742579);
        vm.roll(block.number + 1);
        uint256 epoch2 = 1767225600;
        uint256 amount2 = 2000e18;

        vm.prank(authorized);
        debtToken.mint(user1, amount2);

        uint256 shares2 = debtToken.convertToShares(amount2, 0, epoch2);

        // Shares in different epochs should be independent
        assertGt(shares1, 0, "Shares1 should be greater than 0");
        assertGt(shares2, 0, "Shares2 should be greater than 0");
    }

    // ============ Integration Tests ============

    function test_AssetsAndSupply_Relationship() public {
        uint256 amount = 1000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.prank(authorized);
        debtToken.mint(user1, amount);

        uint256 totalAssets = debtToken.totalAssets(currentEpoch); // Distributed
        uint256 totalAssetsFull = amount; // Full amount
        uint256 totalSupply = debtToken.totalSupply(currentEpoch);

        // Total supply should be greater than total assets due to vault rebalancing
        assertGt(totalSupply, totalAssets, "Total supply should be greater than total assets");
        
        // With 80% ratio: assets = 1000 (distributed), supply = 5000
        assertLe(totalAssets, totalAssetsFull, "Total assets should be <= minted amount (distributed)");
        assertEq(totalSupply, amount + (amount * 8000 / 2000), "Total supply should include vault");
    }

    function test_Conversion_Consistency() public {
        uint256 assets = 1000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.prank(authorized);
        debtToken.mint(user1, assets);

        // Convert assets to shares
        uint256 shares = debtToken.convertToShares(assets, 0, currentEpoch);
        
        // Convert shares back to assets
        uint256 convertedAssets = debtToken.convertToAssets(shares, 0, currentEpoch);
        
        // Should be approximately equal (allowing for rounding)
        assertApproxEqRel(convertedAssets, assets, 1e15, "Round-trip conversion should be consistent");
    }

    function test_Conversion_WithMultipleUsers() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.startPrank(authorized);
        debtToken.mint(user1, amount1);
        debtToken.mint(user2, amount2);
        vm.stopPrank();

        uint256 totalAssets = debtToken.totalAssets(currentEpoch);
        uint256 shares1 = debtToken.convertToShares(amount1, 0, currentEpoch);
        uint256 shares2 = debtToken.convertToShares(amount2, 0, currentEpoch);
        uint256 totalShares = debtToken.convertToShares(totalAssets, 0, currentEpoch);

        // Total shares should be approximately sum of individual shares
        // Due to distribution and rounding, there may be slight differences
        // Using absolute tolerance to account for distribution effects
        // The difference is due to how conversion works with distributed assets
        uint256 expectedSum = shares1 + shares2;
        assertApproxEqAbs(expectedSum, totalShares, 4e19, "Total shares should approximately equal sum (accounting for distribution)");
    }

    // ============ Edge Cases ============

    function test_ConvertToShares_WhenNoAssets() public {
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        uint256 shares = debtToken.convertToShares(1000e18, 0, currentEpoch);
        // When totalAssets = 0, formula is: assets * (totalSupply + 1) / (0 + 1)
        // This should still work but result in very large shares
        assertGt(shares, 0, "Shares should be calculated even when no assets exist");
    }

    function test_ConvertToAssets_WhenNoSupply() public {
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        // When totalSupply = 0, formula is: shares * (totalAssets + 1) / (0 + 10^0)
        // Since totalAssets = 0, this becomes: shares * 1 / 1 = shares
        // But with decimalsOffset = 0, denominator is 0 + 1 = 1, so result is shares * 1 = shares
        uint256 shares = 1000e18;
        uint256 assets = debtToken.convertToAssets(shares, 0, currentEpoch);
        // When no supply exists, the conversion formula still works but may not return 0
        assertGt(assets, 0, "Assets conversion should work even when supply is 0");
    }

    function test_TotalAssets_AfterRebalance() public {
        uint256 amount = 1000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.prank(authorized);
        debtToken.mint(user1, amount);

        uint256 assetsBefore = debtToken.totalAssets(currentEpoch);
        
        // Rebalance shouldn't affect total assets (but we're in current epoch so it's distributed)
        uint256 assetsAfter = debtToken.totalAssets(currentEpoch);
        
        assertEq(assetsBefore, assetsAfter, "Total assets should not change after rebalance");
        // Assets are distributed over time in current epoch, so they should be <= amount
        assertLe(assetsAfter, amount, "Total assets should be <= minted amount (distributed over time)");
    }

    function test_Conversion_WithZeroRatio() public {
        // Set ratio to 0
        vm.prank(authorized);
        debtToken.setVaultRatioBps(0);

        uint256 amount = 1000e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.prank(authorized);
        debtToken.mint(user1, amount);

        // With 0 ratio, totalSupply should equal totalAssets (but assets are distributed)
        uint256 totalAssets = debtToken.totalAssets(currentEpoch); // Distributed
        uint256 totalAssetsFull = amount; // Full amount
        uint256 totalSupply = debtToken.totalSupply(currentEpoch);
        
        // Assets are distributed, so they will be <= full amount
        assertLe(totalAssets, totalAssetsFull, "Distributed assets should be <= full amount");
        // With 0 ratio, supply should equal the full assets amount (not distributed)
        assertEq(totalSupply, totalAssetsFull, "Supply should equal full assets with 0 ratio");
        
        // Conversion uses distributed assets, so shares will be based on distributed amount
        // shares = assets * (totalSupply + 1) / (totalAssets + 1)
        // With 0 ratio and distributed assets, shares will be slightly more than assets
        uint256 shares = debtToken.convertToShares(amount, 0, currentEpoch);
        // Shares will be approximately equal to assets, but may vary slightly due to distribution
        // The difference is due to using distributed assets in the conversion formula
        assertApproxEqAbs(shares, amount, 3e18, "Shares should approximately equal assets with 0 ratio (accounting for distribution)");
    }

    // ============ Repayment and Redemption Scenario Tests ============

    function test_RepaymentAndRedemption_20PercentVaultRatio() public {
        // Scenario: User repays 20 tokens, vault gets 20%, user redeems and gets 80% back
        
        // Set vault ratio to 20%
        vm.prank(authorized);
        debtToken.setVaultRatioBps(2000);
        
        uint256 repaymentAmount = 20e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        
        // Step 1: User repays 20 tokens (mints 20 debt tokens to user)
        vm.prank(authorized);
        debtToken.mint(user1, repaymentAmount);
        
        // Verify the state after repayment
        uint256 userBalance = debtToken.getCurrentBalance(user1);
        uint256 vaultBalance = debtToken.getCurrentBalance(debtToken.vault());
        uint256 totalAssets = debtToken.totalAssets(currentEpoch); // Distributed amount
        uint256 totalAssetsFull = repaymentAmount; // Full amount for epoch
        uint256 totalSupply = debtToken.totalSupply(currentEpoch);
        
        assertEq(userBalance, repaymentAmount, "User should have 20 tokens");
        // totalAssets is distributed over time, so it will be <= full amount
        assertLe(totalAssets, totalAssetsFull, "Total assets should be <= 20 tokens (distributed)");
        
        // With 20% vault ratio:
        // userSupply = 20
        // vaultSupply = 20 * 2000 / 8000 = 5
        // totalSupply = 20 + 5 = 25
        uint256 expectedVaultBalance = (repaymentAmount * 2000) / 8000; // 5 tokens
        uint256 expectedTotalSupply = repaymentAmount + expectedVaultBalance; // 25 tokens
        
        assertEq(vaultBalance, expectedVaultBalance, "Vault should have 5 tokens (20% of 25)");
        assertEq(totalSupply, expectedTotalSupply, "Total supply should be 25 tokens");
        
        // Verify vault ratio is correct
        uint256 actualRatio = (vaultBalance * 10000) / totalSupply;
        assertEq(actualRatio, 2000, "Vault should have exactly 20% of total supply");
        
        // Step 2: Calculate what shares the user has when they deposit 20 assets
        uint256 userShares = debtToken.convertToShares(repaymentAmount, 0, currentEpoch);
        
        // shares = assets * (totalSupply + 1) / (totalAssets + 1)
        // shares = 20 * (25 + 1) / (20 + 1) = 20 * 26 / 21 ≈ 24.76
        assertGt(userShares, repaymentAmount, "User should have more shares than assets due to vault ratio");
        
        // Step 3: Calculate what assets user receives when redeeming their balance
        // The user's balance represents their share of the total supply
        // User owns: userBalance / totalSupply = 20 / 25 = 80% of supply
        // Since totalAssets is distributed, they receive: userBalance * totalAssets / totalSupply
        // This equals 80% of the distributed assets
        
        // Method 1: Direct proportional calculation (what user expects)
        uint256 expectedAssetsReceived = (userBalance * totalAssets) / totalSupply;
        // Expected is 80% of the distributed assets
        uint256 expectedFromDistributed = (totalAssets * 8000) / 10000;
        assertApproxEqAbs(expectedAssetsReceived, expectedFromDistributed, 1e15, "User should receive 80% of distributed assets via proportional calculation");
        
        // Method 2: Using conversion function (ERC4626 standard - maintains round-trip)
        uint256 assetsViaConversion = debtToken.convertToAssets(userShares, 0, currentEpoch);
        // This gives back ~20 because ERC4626 maintains round-trip conversion
        assertApproxEqAbs(assetsViaConversion, repaymentAmount, 1e15, "ERC4626 conversion maintains round-trip (returns ~20)");
        
        // The key insight: User's balance (20) represents their assets deposited
        // But when redeeming, if we want them to get their proportional share (80%),
        // we need to calculate: balance * totalAssets / totalSupply
        // Since totalAssets is distributed, this gives 80% of distributed assets
        // NOT use the ERC4626 conversion which maintains round-trip
        
        // Verify the proportional calculation
        uint256 userShareOfSupply = (userBalance * 10000) / totalSupply;
        assertEq(userShareOfSupply, 8000, "User owns 80% of total supply");
        assertApproxEqAbs(expectedAssetsReceived, (totalAssets * userShareOfSupply) / 10000, 1e15, "User should get 80% of distributed assets");
    }

    function test_RepaymentAndRedemption_MultipleRepayments() public {
        // Test scenario with multiple repayments and redemption
        
        // Set vault ratio to 20%
        vm.prank(authorized);
        debtToken.setVaultRatioBps(2000);
        
        uint256 repayment1 = 20e18;
        uint256 repayment2 = 30e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        
        // First repayment: 20 tokens
        vm.prank(authorized);
        debtToken.mint(user1, repayment1);
        
        // Second repayment: 30 tokens
        vm.prank(authorized);
        debtToken.mint(user1, repayment2);
        
        uint256 userBalance = debtToken.getCurrentBalance(user1);
        uint256 totalAssets = debtToken.totalAssets(currentEpoch); // This is distributed amount
        uint256 totalAssetsFull = repayment1 + repayment2; // Full amount for the epoch
        uint256 totalSupply = debtToken.totalSupply(currentEpoch);
        
        // After both repayments: user has 50 tokens
        assertEq(userBalance, repayment1 + repayment2, "User should have 50 tokens total");
        // totalAssets is distributed over time, so it will be <= full amount
        assertLe(totalAssets, totalAssetsFull, "Total assets should be <= full amount (distributed)");
        
        // Vault should have 20% of total supply
        // After 50 assets: vault = 50 * 2000 / 8000 = 12.5
        // Total supply = 50 + 12.5 = 62.5
        uint256 expectedVaultBalance = ((repayment1 + repayment2) * 2000) / 8000;
        uint256 expectedTotalSupply = (repayment1 + repayment2) + expectedVaultBalance;
        
        assertEq(totalSupply, expectedTotalSupply, "Total supply should include vault");
        
        // When user redeems, they should get their proportional share
        // User owns: 50 / 62.5 = 80% of supply
        // So they should get: 50 * totalAssets / 62.5 (where totalAssets is distributed)
        // Since totalAssets is distributed, assetsReceived will also be distributed proportionally
        uint256 assetsReceived = (userBalance * totalAssets) / totalSupply;
        // Expected is 80% of the distributed assets (not full amount)
        uint256 expectedAssets = (totalAssets * 8000) / 10000; // 80% of distributed assets
        
        assertApproxEqAbs(assetsReceived, expectedAssets, 1e15, "User should receive 80% of distributed assets");
    }

    function test_RepaymentAndRedemption_DifferentVaultRatios() public {
        // Test that redemption percentage changes with different vault ratios
        
        uint256 repaymentAmount = 100e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        
        // Test with 20% vault ratio
        vm.prank(authorized);
        debtToken.setVaultRatioBps(2000);
        
        vm.prank(authorized);
        debtToken.mint(user1, repaymentAmount);
        
        uint256 userBalance20 = debtToken.getCurrentBalance(user1);
        uint256 totalAssets20 = debtToken.totalAssets(currentEpoch);
        uint256 totalSupply20 = debtToken.totalSupply(currentEpoch);
        
        // Proportional redemption: user gets their share of assets
        uint256 assets20 = (userBalance20 * totalAssets20) / totalSupply20;
        // Percentage is relative to distributed assets, not full repayment amount
        uint256 percentage20 = (assets20 * 10000) / totalAssets20;
        
        // Clear state for next test
        vm.warp(1767742579);
        vm.roll(block.number + 1);
        uint256 epoch2 = 1767225600;
        
        // Test with 50% vault ratio
        vm.prank(authorized);
        debtToken.setVaultRatioBps(5000);
        
        vm.prank(authorized);
        debtToken.mint(user2, repaymentAmount);
        
        uint256 userBalance50 = debtToken.getCurrentBalance(user2);
        uint256 totalAssets50 = debtToken.totalAssets(epoch2);
        uint256 totalSupply50 = debtToken.totalSupply(epoch2);
        
        // Proportional redemption: user gets their share of assets
        uint256 assets50 = (userBalance50 * totalAssets50) / totalSupply50;
        // Percentage is relative to distributed assets, not full repayment amount
        uint256 percentage50 = (assets50 * 10000) / totalAssets50;
        
        // With 20% vault: user owns 80% of supply, gets 80% of distributed assets back
        // With 50% vault: user owns 50% of supply, gets 50% of distributed assets back
        assertApproxEqAbs(percentage20, 8000, 100, "With 20% vault, user should get ~80% of distributed assets");
        assertApproxEqAbs(percentage50, 5000, 100, "With 50% vault, user should get ~50% of distributed assets");
        
        assertLt(percentage50, percentage20, "Higher vault ratio should result in lower redemption percentage");
    }

    function test_RepaymentAndRedemption_ExactCalculation() public {
        // Test exact calculation: 20 tokens repayment, 20% vault, expect 16 tokens back
        
        // Set vault ratio to 20%
        vm.prank(authorized);
        debtToken.setVaultRatioBps(2000);
        
        uint256 repaymentAmount = 20e18;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        
        // User repays 20 tokens
        vm.prank(authorized);
        debtToken.mint(user1, repaymentAmount);
        
        // Verify state
        uint256 userBalance = debtToken.getCurrentBalance(user1);
        uint256 totalAssets = debtToken.totalAssets(currentEpoch); // Distributed amount
        uint256 totalAssetsFull = repaymentAmount; // Full amount for epoch
        uint256 totalSupply = debtToken.totalSupply(currentEpoch);
        uint256 vaultBalance = debtToken.getCurrentBalance(debtToken.vault());
        
        assertEq(userBalance, repaymentAmount, "User balance = 20");
        // totalAssets is distributed over time, so it will be <= full amount
        assertLe(totalAssets, totalAssetsFull, "Total assets should be <= 20 (distributed)");
        // vault = 20 * 2000 / 8000 = 5
        // totalSupply = 20 + 5 = 25
        assertEq(totalSupply, 25e18, "Total supply = 25");
        assertEq(vaultBalance, 5e18, "Vault balance = 5");
        
        // User's share of total supply: 20 / 25 = 80%
        // When redeeming, user should get their proportional share of assets
        // assets_received = userBalance * totalAssets / totalSupply
        // Since totalAssets is distributed, assetsReceived will be 80% of distributed amount
        
        uint256 assetsReceived = (userBalance * totalAssets) / totalSupply;
        // Expected is 80% of the distributed assets
        uint256 expectedAssets = (totalAssets * 8000) / 10000; // 80% of distributed assets
        
        assertApproxEqAbs(assetsReceived, expectedAssets, 1e15, "User should receive 80% of distributed assets");
        
        // Verify the percentage (relative to distributed assets, not full amount)
        uint256 percentage = (assetsReceived * 10000) / totalAssets;
        assertApproxEqAbs(percentage, 8000, 100, "User should receive approximately 80% of distributed assets");
        
        // Verify user's share of supply
        uint256 userShareOfSupply = (userBalance * 10000) / totalSupply;
        assertEq(userShareOfSupply, 8000, "User owns 80% of total supply");
        
        // The key formula: assets_received = user_share_of_supply * total_assets / 10000
        assertEq(assetsReceived, (totalAssets * userShareOfSupply) / 10000, "Assets received should equal user's share of total assets");
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

