// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {DebtToken} from "../../vault/DebtToken.sol";
import {FeeCalculator} from "../../vault/FeeCalculator.sol";
import {IFeeCalculator} from "../../vault/IFeeCalculator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolTimeLibrary} from "../../src/libraries/ProtocolTimeLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MockVault
 * @notice Simple mock vault for testing DebtToken
 */
contract MockVault {
    uint256 public utilizationPercent = 5000; // Default 50%

    function setUtilizationPercent(uint256 _utilization) external {
        utilizationPercent = _utilization;
    }

    function getUtilizationPercent() external view returns (uint256) {
        return utilizationPercent;
    }

    function decreaseTotalLoanedAssets(uint256) external {
        // No-op for testing
    }
}

/**
 * @title MockFeeCalculator
 * @notice Mock fee calculator that returns a configurable fixed rate
 */
contract MockFeeCalculator is IFeeCalculator {
    uint256 public fixedRate;

    constructor(uint256 _rate) {
        fixedRate = _rate;
    }

    function setRate(uint256 _rate) external {
        fixedRate = _rate;
    }

    function getVaultRatioBps(uint256) external view override returns (uint256) {
        return fixedRate;
    }
}

/**
 * @title DebtTokenTest
 * @notice Comprehensive test suite for upgradeable DebtToken
 */
contract DebtTokenTest is Test {
    DebtToken public debtToken;
    DebtToken public debtTokenImpl;
    MockVault public mockVault;
    FeeCalculator public feeCalculator;

    address public owner;
    address public user1;
    address public user2;
    address public user3;

    uint256 constant WEEK = 7 days;

    function setUp() public {
        // Start at week 2 to avoid epoch 0 edge cases
        vm.warp(2 * ProtocolTimeLibrary.WEEK);

        owner = address(0x100);
        user1 = address(0x1);
        user2 = address(0x2);
        user3 = address(0x3);

        // Deploy mock vault
        mockVault = new MockVault();

        // Deploy fee calculator
        feeCalculator = new FeeCalculator();

        // Deploy DebtToken implementation
        debtTokenImpl = new DebtToken();

        // Deploy DebtToken proxy
        bytes memory initData = abi.encodeWithSelector(
            DebtToken.initialize.selector,
            address(mockVault),
            address(feeCalculator),
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(debtTokenImpl), initData);
        debtToken = DebtToken(address(proxy));
    }

    // ============ Initialization Tests ============

    function test_Initialize_SetsVault() public view {
        assertEq(debtToken.vault(), address(mockVault), "Vault should be set correctly");
    }

    function test_Initialize_SetsFeeCalculator() public view {
        assertEq(debtToken.feeCalculator(), address(feeCalculator), "Fee calculator should be set correctly");
    }

    function test_Initialize_SetsOwner() public view {
        assertEq(debtToken.owner(), owner, "Owner should be set correctly");
    }

    function test_Initialize_RevertWhen_ZeroVault() public {
        DebtToken newImpl = new DebtToken();
        bytes memory initData = abi.encodeWithSelector(
            DebtToken.initialize.selector,
            address(0),
            address(feeCalculator),
            owner
        );
        vm.expectRevert(DebtToken.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialize_RevertWhen_ZeroFeeCalculator() public {
        DebtToken newImpl = new DebtToken();
        bytes memory initData = abi.encodeWithSelector(
            DebtToken.initialize.selector,
            address(mockVault),
            address(0),
            owner
        );
        vm.expectRevert(DebtToken.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialize_RevertWhen_ZeroOwner() public {
        DebtToken newImpl = new DebtToken();
        bytes memory initData = abi.encodeWithSelector(
            DebtToken.initialize.selector,
            address(mockVault),
            address(feeCalculator),
            address(0)
        );
        vm.expectRevert(DebtToken.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    // ============ Basic Mint Tests ============

    function test_Mint_SingleMint() public {
        uint256 amount = 1000e18;

        vm.prank(address(mockVault));
        debtToken.mint(user1, amount);

        // Check balance checkpoint was created
        assertEq(debtToken.numCheckpoints(user1), 1, "Should have 1 checkpoint");

        // Check total assets per epoch
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        assertEq(debtToken.totalAssetsPerEpoch(currentEpoch), amount, "Total assets should match minted amount");
    }

    function test_Mint_MultipleMintsSameUser() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        uint256 amount3 = 500e18;
        uint256 total = amount1 + amount2 + amount3;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.startPrank(address(mockVault));
        debtToken.mint(user1, amount1);
        debtToken.mint(user1, amount2);
        debtToken.mint(user1, amount3);
        vm.stopPrank();

        // Check total assets
        assertEq(debtToken.totalAssetsPerEpoch(currentEpoch), total, "Total assets should be sum of all mints");
    }

    function test_Mint_MultipleUsers() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        uint256 amount3 = 1500e18;
        uint256 total = amount1 + amount2 + amount3;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.startPrank(address(mockVault));
        debtToken.mint(user1, amount1);
        debtToken.mint(user2, amount2);
        debtToken.mint(user3, amount3);
        vm.stopPrank();

        // Check individual checkpoints exist
        assertEq(debtToken.numCheckpoints(user1), 1, "User1 should have checkpoint");
        assertEq(debtToken.numCheckpoints(user2), 1, "User2 should have checkpoint");
        assertEq(debtToken.numCheckpoints(user3), 1, "User3 should have checkpoint");

        // Check total assets
        assertEq(debtToken.totalAssetsPerEpoch(currentEpoch), total, "Total assets should include all users");
    }

    // ============ Authorization Tests ============

    function test_Mint_RevertWhen_NotVault() public {
        uint256 amount = 1000e18;

        vm.prank(user1);
        vm.expectRevert(DebtToken.NotAuthorized.selector);
        debtToken.mint(user1, amount);
    }

    function test_Mint_RevertWhen_ZeroAmount() public {
        vm.prank(address(mockVault));
        vm.expectRevert(DebtToken.ZeroAmount.selector);
        debtToken.mint(user1, 0);
    }

    // ============ Fee Calculator Tests ============

    function test_SetFeeCalculator_UpdatesCalculator() public {
        MockFeeCalculator newCalc = new MockFeeCalculator(3000);

        vm.prank(owner);
        debtToken.setFeeCalculator(address(newCalc));

        assertEq(debtToken.feeCalculator(), address(newCalc), "Fee calculator should be updated");
    }

    function test_SetFeeCalculator_RevertWhen_NotOwner() public {
        MockFeeCalculator newCalc = new MockFeeCalculator(3000);

        vm.prank(user1);
        vm.expectRevert();
        debtToken.setFeeCalculator(address(newCalc));
    }

    function test_SetFeeCalculator_RevertWhen_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(DebtToken.ZeroAddress.selector);
        debtToken.setFeeCalculator(address(0));
    }

    function test_SetFeeCalculator_EmitsEvent() public {
        MockFeeCalculator newCalc = new MockFeeCalculator(3000);
        address oldCalc = debtToken.feeCalculator();

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit DebtToken.FeeCalculatorUpdated(oldCalc, address(newCalc));
        debtToken.setFeeCalculator(address(newCalc));
    }

    function test_GetVaultRatioBps_UsesFeeCalculator() public {
        // Default fee calculator at 50% utilization returns 2000 bps (20%)
        mockVault.setUtilizationPercent(5000);
        uint256 rate = debtToken.getVaultRatioBps(5000);
        assertEq(rate, 2000, "Should return 20% at 50% utilization");

        // Swap to custom fee calculator
        MockFeeCalculator customCalc = new MockFeeCalculator(6000);
        vm.prank(owner);
        debtToken.setFeeCalculator(address(customCalc));

        rate = debtToken.getVaultRatioBps(5000);
        assertEq(rate, 6000, "Should return custom rate after swap");
    }

    // ============ Rebalance Tests ============

    function test_Rebalance_OnlyVaultCanCall() public {
        vm.prank(user1);
        vm.expectRevert(DebtToken.NotAuthorized.selector);
        debtToken.rebalance();
    }

    function test_Rebalance_VaultCanCall() public {
        // First mint something to have state
        vm.prank(address(mockVault));
        debtToken.mint(user1, 1000e18);

        // Rebalance should work
        vm.prank(address(mockVault));
        debtToken.rebalance();
    }

    function test_Rebalance_UpdatesVaultBalance() public {
        mockVault.setUtilizationPercent(5000); // 50% utilization -> 20% fee

        vm.prank(address(mockVault));
        debtToken.mint(user1, 1000e18);

        // At 20% ratio: vault gets 1000 * 2000 / 8000 = 250
        // Total supply = 1000 + 250 = 1250
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        uint256 totalSupply = debtToken.totalSupplyPerEpoch(currentEpoch);

        // Verify rebalancing occurred
        assertGt(totalSupply, 1000e18, "Total supply should include vault balance");
    }

    // ============ Epoch Tests ============

    function test_Mint_DifferentEpochs() public {
        // Start at beginning of an epoch
        uint256 epoch1 = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(epoch1);

        uint256 amount1 = 1000e18;

        vm.prank(address(mockVault));
        debtToken.mint(user1, amount1);

        assertEq(debtToken.totalAssetsPerEpoch(epoch1), amount1, "Epoch1 assets should match");

        // Move to next epoch
        uint256 epoch2 = ProtocolTimeLibrary.epochNext(epoch1);
        vm.warp(epoch2);
        uint256 amount2 = 2000e18;

        vm.prank(address(mockVault));
        debtToken.mint(user1, amount2);

        // Check epoch-specific assets
        assertEq(debtToken.totalAssetsPerEpoch(epoch1), amount1, "Epoch1 assets should remain unchanged");
        assertEq(debtToken.totalAssetsPerEpoch(epoch2), amount2, "Epoch2 assets should match");
    }

    function test_Mint_SameEpochMultipleTimes() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        uint256 total = amount1 + amount2;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.startPrank(address(mockVault));
        debtToken.mint(user1, amount1);
        debtToken.mint(user1, amount2);
        vm.stopPrank();

        assertEq(debtToken.totalAssetsPerEpoch(currentEpoch), total, "Total assets should accumulate");
    }

    // ============ Checkpoint Tests ============

    function test_Mint_CreatesCheckpoint() public {
        uint256 amount = 1000e18;

        vm.prank(address(mockVault));
        debtToken.mint(user1, amount);

        assertEq(debtToken.numCheckpoints(user1), 1, "Should have 1 checkpoint");

        (uint256 epoch, uint256 balance) = debtToken.checkpoints(user1, 0);
        assertEq(balance, amount, "Checkpoint balance should match");
        assertEq(epoch, ProtocolTimeLibrary.epochStart(block.timestamp), "Checkpoint epoch should match");
    }

    function test_Mint_UpdatesCheckpointInSameEpoch() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        uint256 total = amount1 + amount2;

        vm.startPrank(address(mockVault));
        debtToken.mint(user1, amount1);
        uint256 checkpointsBefore = debtToken.numCheckpoints(user1);
        debtToken.mint(user1, amount2);
        vm.stopPrank();

        // In the same epoch, checkpoint should be updated, not created
        assertEq(debtToken.numCheckpoints(user1), checkpointsBefore, "Should not create new checkpoint in same epoch");

        (uint256 epoch, uint256 balance) = debtToken.checkpoints(user1, 0);
        assertEq(balance, total, "Checkpoint balance should be updated");
    }

    function test_Mint_CreatesNewCheckpointInNewEpoch() public {
        uint256 amount1 = 1000e18;

        vm.prank(address(mockVault));
        debtToken.mint(user1, amount1);

        uint256 checkpointsBefore = debtToken.numCheckpoints(user1);

        // Move to next epoch
        vm.warp(block.timestamp + WEEK);
        uint256 amount2 = 2000e18;

        vm.prank(address(mockVault));
        debtToken.mint(user1, amount2);

        // Should create new checkpoint in new epoch
        assertEq(debtToken.numCheckpoints(user1), checkpointsBefore + 1, "Should create new checkpoint in new epoch");
    }

    // ============ Event Tests ============

    function test_Mint_EmitsEvent() public {
        uint256 amount = 1000e18;

        vm.prank(address(mockVault));
        vm.expectEmit(true, false, false, true);
        emit DebtToken.Mint(user1, amount);
        debtToken.mint(user1, amount);
    }

    // ============ Total Supply Tests ============

    function test_TotalSupply_ReturnsCurrentEpoch() public {
        mockVault.setUtilizationPercent(5000);

        vm.prank(address(mockVault));
        debtToken.mint(user1, 1000e18);

        uint256 totalSupply = debtToken.totalSupply();
        assertGt(totalSupply, 0, "Total supply should be > 0");
    }

    function test_TotalSupply_DifferentEpochs() public {
        mockVault.setUtilizationPercent(5000);
        uint256 epoch1 = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.prank(address(mockVault));
        debtToken.mint(user1, 1000e18);

        uint256 supply1 = debtToken.totalSupply(epoch1);

        // Move to next epoch
        vm.warp(block.timestamp + WEEK);
        uint256 epoch2 = ProtocolTimeLibrary.epochStart(block.timestamp);

        vm.prank(address(mockVault));
        debtToken.mint(user1, 2000e18);

        // Supplies should be different
        assertEq(debtToken.totalSupply(epoch1), supply1, "Epoch1 supply should remain unchanged");
        assertGt(debtToken.totalSupply(epoch2), 0, "Epoch2 supply should be > 0");
    }

    // ============ Total Assets Tests ============

    function test_TotalAssets_ReturnsCurrentEpoch() public {
        uint256 amount = 1000e18;

        vm.prank(address(mockVault));
        debtToken.mint(user1, amount);

        uint256 totalAssets = debtToken.totalAssets();
        assertEq(totalAssets, amount, "Total assets should match minted amount");
    }

    function test_TotalAssets_ProratedForCurrentEpoch() public {
        uint256 amount = 1000e18;
        uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);

        // Warp to start of epoch
        vm.warp(epochStart);

        vm.prank(address(mockVault));
        debtToken.mint(user1, amount);

        // At the start, prorated amount should be 0 or very small
        uint256 proratedAssets = debtToken.totalAssets(epochStart);
        assertLt(proratedAssets, amount, "Prorated assets should be less than full amount at epoch start");

        // Warp to middle of epoch
        vm.warp(epochStart + WEEK / 2);
        proratedAssets = debtToken.totalAssets(epochStart);
        assertApproxEqAbs(proratedAssets, amount / 2, 1e15, "Prorated assets should be ~50% at epoch midpoint");

        // Warp to near end of epoch
        vm.warp(epochStart + WEEK - 1);
        proratedAssets = debtToken.totalAssets(epochStart);
        assertApproxEqAbs(proratedAssets, amount, 2e15, "Prorated assets should be ~100% at epoch end");
    }

    function test_TotalAssets_PastEpochReturnsFullAmount() public {
        // Start at beginning of an epoch
        uint256 epoch1 = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(epoch1);

        uint256 amount = 1000e18;

        vm.prank(address(mockVault));
        debtToken.mint(user1, amount);

        // Move to next epoch
        uint256 epoch2 = ProtocolTimeLibrary.epochNext(epoch1);
        vm.warp(epoch2);

        // Past epoch should return full amount
        assertEq(debtToken.totalAssets(epoch1), amount, "Past epoch should return full amount");
    }

    // ============ getPriorBalanceIndex Tests ============

    function test_GetPriorBalanceIndex_NoCheckpoints() public view {
        uint256 index = debtToken.getPriorBalanceIndex(user1, block.timestamp);
        assertEq(index, 0, "Should return 0 when no checkpoints");
    }

    function test_GetPriorBalanceIndex_SingleCheckpoint() public {
        vm.prank(address(mockVault));
        debtToken.mint(user1, 1000e18);

        uint256 index = debtToken.getPriorBalanceIndex(user1, block.timestamp);
        assertEq(index, 0, "Should return 0 for single checkpoint");
    }

    function test_GetPriorBalanceIndex_MultipleCheckpoints() public {
        // Start at beginning of an epoch
        uint256 epoch1 = ProtocolTimeLibrary.epochStart(block.timestamp);
        vm.warp(epoch1);

        // Create checkpoint in epoch 1
        vm.prank(address(mockVault));
        debtToken.mint(user1, 1000e18);
        assertEq(debtToken.numCheckpoints(user1), 1, "Should have 1 checkpoint after epoch1");

        // Move to epoch 2 and create another checkpoint
        uint256 epoch2 = ProtocolTimeLibrary.epochNext(epoch1);
        vm.warp(epoch2);
        vm.prank(address(mockVault));
        debtToken.mint(user1, 2000e18);
        assertEq(debtToken.numCheckpoints(user1), 2, "Should have 2 checkpoints after epoch2");

        // Move to epoch 3 and create another checkpoint
        uint256 epoch3 = ProtocolTimeLibrary.epochNext(epoch2);
        vm.warp(epoch3);
        vm.prank(address(mockVault));
        debtToken.mint(user1, 3000e18);
        assertEq(debtToken.numCheckpoints(user1), 3, "Should have 3 checkpoints after epoch3");

        // Query for current timestamp should return last index
        uint256 index = debtToken.getPriorBalanceIndex(user1, block.timestamp);
        assertEq(index, 2, "Should return latest checkpoint index");
    }

    // ============ Upgrade Tests ============

    function test_Upgrade_OnlyOwnerCanUpgrade() public {
        DebtToken newImpl = new DebtToken();

        vm.prank(user1);
        vm.expectRevert();
        debtToken.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_OwnerCanUpgrade() public {
        DebtToken newImpl = new DebtToken();

        // Get state before upgrade
        address vaultBefore = debtToken.vault();
        address feeCalcBefore = debtToken.feeCalculator();

        vm.prank(owner);
        debtToken.upgradeToAndCall(address(newImpl), "");

        // State should be preserved
        assertEq(debtToken.vault(), vaultBefore, "Vault should be preserved");
        assertEq(debtToken.feeCalculator(), feeCalcBefore, "Fee calculator should be preserved");
    }

    function test_Upgrade_PreservesState() public {
        // Create some state
        vm.prank(address(mockVault));
        debtToken.mint(user1, 1000e18);

        uint256 numCheckpointsBefore = debtToken.numCheckpoints(user1);
        uint256 supplyCheckpointsBefore = debtToken.supplyNumCheckpoints();

        // Upgrade
        DebtToken newImpl = new DebtToken();
        vm.prank(owner);
        debtToken.upgradeToAndCall(address(newImpl), "");

        // State should be preserved
        assertEq(debtToken.numCheckpoints(user1), numCheckpointsBefore, "Checkpoints should be preserved");
        assertEq(debtToken.supplyNumCheckpoints(), supplyCheckpointsBefore, "Supply checkpoints should be preserved");
    }

    // ============ Edge Cases ============

    function test_Mint_LargeAmount() public {
        uint256 largeAmount = 1e50;

        vm.prank(address(mockVault));
        debtToken.mint(user1, largeAmount);

        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        assertEq(debtToken.totalAssetsPerEpoch(currentEpoch), largeAmount, "Should handle large amounts");
    }

    function test_Mint_ToZeroAddress() public {
        // The contract allows minting to zero address
        vm.prank(address(mockVault));
        debtToken.mint(address(0), 1000e18);

        assertEq(debtToken.numCheckpoints(address(0)), 1, "Should create checkpoint for zero address");
    }

    // ============ Fee Calculator Curve Tests ============

    function test_FeeCalculator_LowUtilization() public view {
        // 0-10% utilization: 5% to 20% fee
        uint256 rate = feeCalculator.getVaultRatioBps(0);
        assertEq(rate, 500, "0% utilization should return 5% fee");

        rate = feeCalculator.getVaultRatioBps(1000);
        assertEq(rate, 2000, "10% utilization should return 20% fee");
    }

    function test_FeeCalculator_MidUtilization() public view {
        // 10-70% utilization: flat 20% fee
        uint256 rate = feeCalculator.getVaultRatioBps(2000);
        assertEq(rate, 2000, "20% utilization should return 20% fee");

        rate = feeCalculator.getVaultRatioBps(5000);
        assertEq(rate, 2000, "50% utilization should return 20% fee");

        rate = feeCalculator.getVaultRatioBps(7000);
        assertEq(rate, 2000, "70% utilization should return 20% fee");
    }

    function test_FeeCalculator_HighUtilization() public view {
        // 70-90% utilization: 20% to 40% fee
        uint256 rate = feeCalculator.getVaultRatioBps(8000);
        assertGt(rate, 2000, "80% utilization should return > 20% fee");
        assertLt(rate, 4000, "80% utilization should return < 40% fee");

        rate = feeCalculator.getVaultRatioBps(9000);
        assertEq(rate, 4000, "90% utilization should return 40% fee");
    }

    function test_FeeCalculator_VeryHighUtilization() public view {
        // 90-100% utilization: 40% to 95% fee
        uint256 rate = feeCalculator.getVaultRatioBps(9500);
        assertGt(rate, 4000, "95% utilization should return > 40% fee");
        assertLt(rate, 9500, "95% utilization should return < 95% fee");

        rate = feeCalculator.getVaultRatioBps(10000);
        assertEq(rate, 9500, "100% utilization should return 95% fee");
    }

    function test_FeeCalculator_RevertWhen_Over100Percent() public {
        vm.expectRevert("Utilization exceeds 100%");
        feeCalculator.getVaultRatioBps(10001);
    }

    // ============ Fuzz Tests ============

    function testFuzz_Mint_AnyAmount(uint256 amount) public {
        vm.assume(amount > 0);
        vm.assume(amount < type(uint128).max); // Reasonable upper bound

        vm.prank(address(mockVault));
        debtToken.mint(user1, amount);

        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        assertEq(debtToken.totalAssetsPerEpoch(currentEpoch), amount, "Total assets should match");
    }

    function testFuzz_FeeCalculator_ValidUtilization(uint256 utilization) public view {
        vm.assume(utilization <= 10000);

        uint256 rate = feeCalculator.getVaultRatioBps(utilization);

        // Rate should be between 500 (5%) and 9500 (95%)
        assertGe(rate, 500, "Rate should be >= 5%");
        assertLe(rate, 9500, "Rate should be <= 95%");
    }
}
