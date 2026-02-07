// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {DynamicCollateralFacet} from "../../../src/facets/account/collateral/DynamicCollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {DynamicLendingFacet} from "../../../src/facets/account/lending/DynamicLendingFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {DynamicVotingEscrowFacet} from "../../../src/facets/account/votingEscrow/DynamicVotingEscrowFacet.sol";
import {ERC721ReceiverFacet} from "../../../src/facets/ERC721ReceiverFacet.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {DeployPortfolioAccountConfig} from "../../../script/portfolio_account/DeployPortfolioAccountConfig.s.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";

/**
 * @title AerodromeDynamicFeesE2E
 * @dev End-to-end test for Aerodrome integration with DynamicFeesVault on Base
 *      Tests the full flow: create lock -> borrow -> process rewards -> pay off loan with overpayment
 */
contract AerodromeDynamicFeesE2E is Test {
    // Base chain addresses
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address public constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4; // veAERO
    address public constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;

    // Test actors
    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public user = address(0x40ac2e);
    address public vaultDepositor = address(0xbbbbb);

    // Core contracts
    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioAccountConfig public portfolioAccountConfig;
    LoanConfig public loanConfig;
    VotingConfig public votingConfig;
    SwapConfig public swapConfig;

    // Portfolio account
    address public portfolioAccount;

    // External contracts
    IVotingEscrow public veAERO = IVotingEscrow(VOTING_ESCROW);
    IERC20 public aero = IERC20(AERO);
    IERC20 public usdc = IERC20(USDC);

    // DynamicFeesVault
    DynamicFeesVault public vault;

    // Test constants
    uint256 public constant LOCK_AMOUNT = 1000 ether; // 1000 AERO tokens
    uint256 public constant VAULT_INITIAL_DEPOSIT = 100_000e6; // 100,000 USDC

    function setUp() public {
        // Fork Base network at a specific block
        uint256 fork = vm.createFork(vm.envString("BASE_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(38869188); // Use same block as other tests

        // Don't warp far into the future - just advance slightly
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        vm.startPrank(DEPLOYER);

        // Deploy PortfolioManager
        portfolioManager = new PortfolioManager(DEPLOYER);

        // Deploy factory with facet registry
        (portfolioFactory, facetRegistry) = portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("aerodrome-dynamic-fees-e2e")))
        );

        // Deploy configs
        DeployPortfolioAccountConfig configDeployer = new DeployPortfolioAccountConfig();
        (portfolioAccountConfig, votingConfig, loanConfig, swapConfig) = configDeployer.deploy();

        // Deploy DynamicFeesVault
        DynamicFeesVault vaultImpl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            USDC,
            "40Acres AERO USDC Vault",
            "40AERO-USDC",
            address(portfolioFactory)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = DynamicFeesVault(address(vaultProxy));

        // Transfer vault ownership
        vault.transferOwnership(DEPLOYER);

        // Configure the PortfolioAccountConfig with the DynamicFeesVault as loan contract
        portfolioAccountConfig.setLoanContract(address(vault));

        // Set up loan config for Aerodrome
        loanConfig.setRewardsRate(2850); // Aerodrome rewards rate
        loanConfig.setMultiplier(52); // 52x multiplier

        portfolioAccountConfig.setLoanConfig(address(loanConfig));

        // Fund the vault with USDC from depositor
        deal(USDC, vaultDepositor, VAULT_INITIAL_DEPOSIT);
        vm.stopPrank();

        // Deposit into vault as vaultDepositor
        vm.startPrank(vaultDepositor);
        usdc.approve(address(vault), VAULT_INITIAL_DEPOSIT);
        vault.deposit(VAULT_INITIAL_DEPOSIT, vaultDepositor);
        vm.stopPrank();

        vm.startPrank(DEPLOYER);

        // Deploy DynamicCollateralFacet
        DynamicCollateralFacet collateralFacet = new DynamicCollateralFacet(
            address(portfolioFactory),
            address(portfolioAccountConfig),
            VOTING_ESCROW
        );
        bytes4[] memory collateralSelectors = new bytes4[](9);
        collateralSelectors[0] = BaseCollateralFacet.addCollateral.selector;
        collateralSelectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        collateralSelectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        collateralSelectors[3] = BaseCollateralFacet.getUnpaidFees.selector;
        collateralSelectors[4] = BaseCollateralFacet.getMaxLoan.selector;
        collateralSelectors[5] = BaseCollateralFacet.getOriginTimestamp.selector;
        collateralSelectors[6] = BaseCollateralFacet.removeCollateral.selector;
        collateralSelectors[7] = BaseCollateralFacet.getCollateralToken.selector;
        collateralSelectors[8] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        facetRegistry.registerFacet(address(collateralFacet), collateralSelectors, "DynamicCollateralFacet");


        // Deploy DynamicVotingEscrowFacet (for creating locks)
        DynamicVotingEscrowFacet votingEscrowFacet = new DynamicVotingEscrowFacet(
            address(portfolioFactory),
            address(portfolioAccountConfig),
            VOTING_ESCROW,
            VOTER
        );
        bytes4[] memory votingEscrowSelectors = new bytes4[](3);
        votingEscrowSelectors[0] = DynamicVotingEscrowFacet.increaseLock.selector;
        votingEscrowSelectors[1] = DynamicVotingEscrowFacet.createLock.selector;
        votingEscrowSelectors[2] = DynamicVotingEscrowFacet.merge.selector;
        facetRegistry.registerFacet(address(votingEscrowFacet), votingEscrowSelectors, "DynamicVotingEscrowFacet");

        // Deploy ERC721ReceiverFacet
        ERC721ReceiverFacet erc721ReceiverFacet = new ERC721ReceiverFacet();
        bytes4[] memory erc721ReceiverSelectors = new bytes4[](1);
        erc721ReceiverSelectors[0] = ERC721ReceiverFacet.onERC721Received.selector;
        facetRegistry.registerFacet(address(erc721ReceiverFacet), erc721ReceiverSelectors, "ERC721ReceiverFacet");

        // Deploy DynamicLendingFacet
        DynamicLendingFacet lendingFacet = new DynamicLendingFacet(
            address(portfolioFactory),
            address(portfolioAccountConfig),
            USDC
        );
        bytes4[] memory lendingSelectors = new bytes4[](5);
        lendingSelectors[0] = BaseLendingFacet.borrow.selector;
        lendingSelectors[1] = BaseLendingFacet.borrowTo.selector;
        lendingSelectors[2] = BaseLendingFacet.pay.selector;
        lendingSelectors[3] = BaseLendingFacet.setTopUp.selector;
        lendingSelectors[4] = BaseLendingFacet.topUp.selector;
        facetRegistry.registerFacet(address(lendingFacet), lendingSelectors, "DynamicLendingFacet");

        vm.stopPrank();

        // Create portfolio account for user
        portfolioAccount = portfolioFactory.createAccount(user);

        // Fund user with tokens
        deal(AERO, user, LOCK_AMOUNT * 10);
        deal(USDC, user, 1_000_000e6);

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    // ============ Helper Functions ============

    function _createLockForUser() internal returns (uint256 tokenId) {
        vm.startPrank(user);

        aero.approve(portfolioAccount, LOCK_AMOUNT);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(DynamicVotingEscrowFacet.createLock.selector, LOCK_AMOUNT);

        bytes[] memory results = portfolioManager.multicall(calldatas, factories);

        // Decode the token ID from the result
        tokenId = abi.decode(results[0], (uint256));

        vm.stopPrank();
    }

    function _borrowFromVault(uint256 amount) internal {
        vm.startPrank(user);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, amount);

        portfolioManager.multicall(calldatas, factories);

        vm.stopPrank();
    }

    function _payLoan(uint256 amount) internal returns (uint256 excess) {
        vm.startPrank(user);

        usdc.approve(portfolioAccount, amount);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseLendingFacet.pay.selector, amount);

        bytes[] memory results = portfolioManager.multicall(calldatas, factories);
        excess = abi.decode(results[0], (uint256));

        vm.stopPrank();
    }

    function _repayWithRewards(uint256 amount) internal {
        // Simulate reward payment going through the vault's repayWithRewards
        vm.startPrank(portfolioAccount);
        deal(USDC, portfolioAccount, amount);
        usdc.approve(address(vault), amount);
        vault.repayWithRewards(amount);
        vm.stopPrank();
    }

    // ============ E2E Test: Full Flow with Overpayment ============

    /**
     * @notice Full E2E test: Create lock -> Borrow -> Process rewards over epochs -> Pay off with overpayment
     */
    function testE2E_AerodromeDynamicFees_LoanPayoffWithOverpayment() public {
        console.log("=== Starting Aerodrome Dynamic Fees E2E Test ===");

        // Step 1: Create lock as collateral
        console.log("\n--- Step 1: Create veAERO lock ---");
        uint256 tokenId = _createLockForUser();
        console.log("Token ID created:", tokenId);

        uint256 lockedCollateral = DynamicCollateralFacet(portfolioAccount).getTotalLockedCollateral();
        console.log("Locked collateral:", lockedCollateral);
        assertGt(lockedCollateral, 0, "Should have locked collateral");

        // Step 2: Borrow against collateral
        console.log("\n--- Step 2: Borrow against collateral ---");
        (uint256 maxLoan,) = DynamicCollateralFacet(portfolioAccount).getMaxLoan();
        console.log("Max loan available:", maxLoan);

        uint256 borrowAmount = maxLoan > 0 ? maxLoan / 2 : 100e6; // Borrow 50% of max or 100 USDC
        if (borrowAmount > 0) {
            uint256 userUsdcBefore = usdc.balanceOf(user);
            _borrowFromVault(borrowAmount);
            uint256 userUsdcAfter = usdc.balanceOf(user);

            console.log("Borrowed amount:", borrowAmount);
            console.log("User USDC received:", userUsdcAfter - userUsdcBefore);

            uint256 debt = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
            uint256 vaultDebt = vault.getDebtBalance(portfolioAccount);
            console.log("Portfolio debt:", debt);
            console.log("Vault debt balance:", vaultDebt);

            assertEq(debt, borrowAmount, "Portfolio debt should match borrowed amount");
            assertEq(vaultDebt, borrowAmount, "Vault debt should match borrowed amount");
        }

        // Step 3: Simulate rewards over multiple epochs
        console.log("\n--- Step 3: Simulate rewards over epochs ---");
        uint256 currentDebt = vault.getDebtBalance(portfolioAccount);
        if (currentDebt > 0) {
            // Simulate 3 epochs of reward payments
            for (uint256 i = 0; i < 3; i++) {
                // Move to next epoch
                uint256 nextEpoch = ProtocolTimeLibrary.epochNext(block.timestamp);
                vm.warp(nextEpoch + 1 hours);

                // Simulate reward payment (25% of original debt per epoch)
                uint256 rewardAmount = borrowAmount / 4;
                _repayWithRewards(rewardAmount);

                console.log("Epoch", i + 1, "- Rewards deposited:", rewardAmount);
            }

            // Move to next epoch to allow rewards to vest
            uint256 finalEpoch = ProtocolTimeLibrary.epochNext(block.timestamp);
            vm.warp(finalEpoch + 1 hours);

            // Sync and update debt balance
            vault.sync();
            vault.updateUserDebtBalance(portfolioAccount);

            uint256 debtAfterRewards = vault.getDebtBalance(portfolioAccount);
            uint256 cachedDebt = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
            console.log("Vault debt after rewards vesting:", debtAfterRewards);
            console.log("Cached debt after sync:", cachedDebt);
            assertLt(debtAfterRewards, currentDebt, "Vault debt should be reduced after rewards");
            assertEq(cachedDebt, debtAfterRewards, "Cached debt should match vault debt after sync");
        }

        // Step 4: Pay off remaining loan with overpayment
        console.log("\n--- Step 4: Pay off loan with overpayment ---");
        uint256 remainingDebt = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        console.log("Remaining debt before final payment:", remainingDebt);

        if (remainingDebt > 0) {
            // Pay 150% of remaining debt (50% overpayment)
            uint256 paymentAmount = (remainingDebt * 150) / 100;
            uint256 userBalanceBefore = usdc.balanceOf(user);

            console.log("Payment amount (with overpayment):", paymentAmount);

            uint256 excess = _payLoan(paymentAmount);

            uint256 userBalanceAfter = usdc.balanceOf(user);
            uint256 finalDebt = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
            uint256 finalVaultDebt = vault.getDebtBalance(portfolioAccount);

            console.log("Excess returned:", excess);
            console.log("Final portfolio debt:", finalDebt);
            console.log("Final vault debt:", finalVaultDebt);
            console.log("User balance change:", int256(userBalanceAfter) - int256(userBalanceBefore));

            // Verify debt is fully paid
            assertEq(finalDebt, 0, "Portfolio debt should be 0 after full payment");
            assertEq(finalVaultDebt, 0, "Vault debt should be 0 after full payment");

            // Verify excess was returned
            assertGt(excess, 0, "Should have excess returned");
            assertApproxEqAbs(excess, paymentAmount - remainingDebt, 1, "Excess should equal overpayment");
        }

        console.log("\n=== E2E Test Complete ===");
    }

    /**
     * @notice Test that excess rewards beyond debt are paid out as USDC
     */
    function testE2E_ExcessRewardsPaidAsUSDC() public {
        console.log("=== Testing Excess Rewards Paid as USDC ===");

        // Create lock and borrow
        _createLockForUser();

        (uint256 maxLoan,) = DynamicCollateralFacet(portfolioAccount).getMaxLoan();
        uint256 borrowAmount = maxLoan > 0 ? maxLoan / 4 : 50e6;

        if (borrowAmount > 0) {
            _borrowFromVault(borrowAmount);

            uint256 initialDebt = vault.getDebtBalance(portfolioAccount);
            console.log("Initial debt:", initialDebt);

            // Move to next epoch (epoch N+1)
            uint256 epochN1 = ProtocolTimeLibrary.epochNext(block.timestamp);
            vm.warp(epochN1 + 1 hours);

            // Repay with rewards that EXCEED the debt (200% of debt)
            uint256 excessiveRewards = initialDebt * 2;
            _repayWithRewards(excessiveRewards);

            console.log("Rewards deposited (2x debt):", excessiveRewards);

            // Move to next epoch for rewards to vest (epoch N+2)
            // Use epochN1 + WEEK to ensure we move forward, not re-calculate from block.timestamp
            uint256 epochN2 = epochN1 + 7 days;
            vm.warp(epochN2 + 1 hours);

            // Record portfolio account USDC balance before update
            uint256 portfolioUsdcBefore = usdc.balanceOf(portfolioAccount);

            // Update debt balance - this should pay excess as USDC
            vault.updateUserDebtBalance(portfolioAccount);

            uint256 portfolioUsdcAfter = usdc.balanceOf(portfolioAccount);
            uint256 finalDebt = vault.getDebtBalance(portfolioAccount);

            console.log("Portfolio USDC received (excess):", portfolioUsdcAfter - portfolioUsdcBefore);
            console.log("Final vault debt:", finalDebt);

            // Verify debt is cleared and excess was transferred
            assertEq(finalDebt, 0, "Debt should be fully cleared");
            assertGt(portfolioUsdcAfter, portfolioUsdcBefore, "Portfolio should receive excess USDC");
        }

        console.log("=== Excess Rewards Test Complete ===");
    }

    /**
     * @notice Test dynamic fees curve affects reward distribution
     */
    function testE2E_DynamicFeesAffectRewardDistribution() public {
        console.log("=== Testing Dynamic Fees Curve ===");

        _createLockForUser();

        (uint256 maxLoan,) = DynamicCollateralFacet(portfolioAccount).getMaxLoan();
        uint256 borrowAmount = maxLoan > 0 ? maxLoan / 2 : 100e6;

        if (borrowAmount > 0) {
            _borrowFromVault(borrowAmount);

            // Check utilization and fee ratio
            uint256 utilization = vault.getUtilizationPercent();
            uint256 feeRatio = vault.getVaultRatioBps(utilization);

            console.log("Utilization (bps):", utilization);
            console.log("Fee ratio (bps):", feeRatio);

            // Fee should be within valid range
            assertGe(feeRatio, 500, "Fee ratio should be at least 5%");
            assertLe(feeRatio, 9500, "Fee ratio should be at most 95%");

            // Move to next epoch
            uint256 nextEpoch = ProtocolTimeLibrary.epochNext(block.timestamp);
            vm.warp(nextEpoch + 1 hours);

            // Repay with rewards
            uint256 rewardAmount = borrowAmount / 2;
            _repayWithRewards(rewardAmount);

            // Move epoch forward and sync
            uint256 vestingEpoch = ProtocolTimeLibrary.epochNext(block.timestamp);
            vm.warp(vestingEpoch + 1 hours);

            vault.sync();

            // Check that lender premium was applied
            uint256 previousEpoch = vestingEpoch - ProtocolTimeLibrary.WEEK;
            uint256 totalRewards = vault.rewardTotalAssetsPerEpoch(previousEpoch);
            uint256 lenderPremium = vault.tokenClaimedPerEpoch(address(vault), previousEpoch);

            console.log("Total rewards in epoch:", totalRewards);
            console.log("Lender premium:", lenderPremium);

            if (totalRewards > 0) {
                uint256 actualFeeRatio = (lenderPremium * 10000) / totalRewards;
                console.log("Actual fee ratio applied (bps):", actualFeeRatio);

                // Fee ratio should be within expected range
                assertGe(actualFeeRatio, 400, "Actual fee should be >= 4%");
                assertLe(actualFeeRatio, 9600, "Actual fee should be <= 96%");
            }
        }

        console.log("=== Dynamic Fees Test Complete ===");
    }

    /**
     * @notice Test multiple borrowers with concurrent reward settlements
     */
    function testE2E_MultipleBorrowersSettlement() public {
        console.log("=== Testing Multiple Borrowers Settlement ===");

        // Create second user
        address user2 = address(0xbeef);
        address portfolioAccount2 = portfolioFactory.createAccount(user2);

        // Fund user2
        deal(AERO, user2, LOCK_AMOUNT * 10);
        deal(USDC, user2, 1_000_000e6);

        // User 1: Create lock and borrow
        _createLockForUser();
        (uint256 maxLoan1,) = DynamicCollateralFacet(portfolioAccount).getMaxLoan();
        uint256 borrow1 = maxLoan1 > 0 ? maxLoan1 / 3 : 50e6;
        if (borrow1 > 0) {
            _borrowFromVault(borrow1);
        }

        // User 2: Create lock and borrow
        vm.startPrank(user2);
        aero.approve(portfolioAccount2, LOCK_AMOUNT);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(DynamicVotingEscrowFacet.createLock.selector, LOCK_AMOUNT);
        portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        (uint256 maxLoan2,) = DynamicCollateralFacet(portfolioAccount2).getMaxLoan();
        uint256 borrow2 = maxLoan2 > 0 ? maxLoan2 / 3 : 50e6;
        if (borrow2 > 0) {
            vm.startPrank(user2);
            calldatas[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, borrow2);
            portfolioManager.multicall(calldatas, factories);
            vm.stopPrank();
        }

        console.log("User1 debt:", vault.getDebtBalance(portfolioAccount));
        console.log("User2 debt:", vault.getDebtBalance(portfolioAccount2));

        // Move to next epoch
        uint256 nextEpoch = ProtocolTimeLibrary.epochNext(block.timestamp);
        vm.warp(nextEpoch + 1 hours);

        // Both users repay with rewards
        if (borrow1 > 0) {
            vm.startPrank(portfolioAccount);
            deal(USDC, portfolioAccount, borrow1 / 2);
            usdc.approve(address(vault), borrow1 / 2);
            vault.repayWithRewards(borrow1 / 2);
            vm.stopPrank();
        }

        if (borrow2 > 0) {
            vm.startPrank(portfolioAccount2);
            deal(USDC, portfolioAccount2, borrow2 / 2);
            usdc.approve(address(vault), borrow2 / 2);
            vault.repayWithRewards(borrow2 / 2);
            vm.stopPrank();
        }

        // Move to next epoch for vesting
        uint256 vestingEpoch = ProtocolTimeLibrary.epochNext(block.timestamp);
        vm.warp(vestingEpoch + 1 hours);

        vault.sync();
        vault.updateUserDebtBalance(portfolioAccount);
        vault.updateUserDebtBalance(portfolioAccount2);

        uint256 debt1After = vault.getDebtBalance(portfolioAccount);
        uint256 debt2After = vault.getDebtBalance(portfolioAccount2);

        console.log("User1 debt after rewards:", debt1After);
        console.log("User2 debt after rewards:", debt2After);

        if (borrow1 > 0) {
            assertLt(debt1After, borrow1, "User1 debt should be reduced");
        }
        if (borrow2 > 0) {
            assertLt(debt2After, borrow2, "User2 debt should be reduced");
        }

        console.log("=== Multiple Borrowers Test Complete ===");
    }

    /**
     * @notice Test vault share price stability with excess rewards
     */
    function testE2E_VaultSharePriceStability() public {
        console.log("=== Testing Vault Share Price Stability ===");

        _createLockForUser();

        // Record initial share price
        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 sharePriceBefore = totalAssetsBefore * 1e18 / totalSupplyBefore;

        console.log("Initial share price:", sharePriceBefore);

        (uint256 maxLoan,) = DynamicCollateralFacet(portfolioAccount).getMaxLoan();
        uint256 borrowAmount = maxLoan > 0 ? maxLoan / 4 : 25e6;

        if (borrowAmount > 0) {
            _borrowFromVault(borrowAmount);

            // Move to next epoch (epoch N+1)
            uint256 epochN1 = ProtocolTimeLibrary.epochNext(block.timestamp);
            vm.warp(epochN1 + 1 hours);

            // Repay with excess rewards (3x debt)
            uint256 excessRewards = borrowAmount * 3;
            _repayWithRewards(excessRewards);

            // Move to next epoch for vesting (epoch N+2)
            // Use explicit calculation to ensure we actually advance
            uint256 epochN2 = epochN1 + 7 days;
            vm.warp(epochN2 + 1 hours);

            vault.updateUserDebtBalance(portfolioAccount);

            uint256 totalSupplyAfter = vault.totalSupply();
            uint256 totalAssetsAfter = vault.totalAssets();
            uint256 sharePriceAfter = totalAssetsAfter * 1e18 / totalSupplyAfter;

            console.log("Final share price:", sharePriceAfter);
            console.log("Share price change:", int256(sharePriceAfter) - int256(sharePriceBefore));

            // Share price should not decrease (no dilution from excess rewards)
            assertGe(sharePriceAfter, sharePriceBefore, "Share price should not decrease");

            // Verify borrower didn't receive vault shares for excess
            uint256 borrowerShares = vault.balanceOf(portfolioAccount);
            assertEq(borrowerShares, 0, "Borrower should not receive vault shares");
        }

        console.log("=== Share Price Stability Test Complete ===");
    }
}
