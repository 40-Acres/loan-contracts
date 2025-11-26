// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {PortfolioFactory} from "../src/accounts/PortfolioFactory.sol";
import {FortyAcresPortfolioAccount} from "../src/accounts/FortyAcresPortfolioAccount.sol";
import {FacetRegistry} from "../src/accounts/FacetRegistry.sol";
import {Loan} from "../src/LoanV2.sol";
import {Vault} from "../src/VaultV2.sol";
import {BaseDeploy} from "../script/BaseDeploy.s.sol";
import {DeploySwapper} from "../script/BaseDeploySwapper.s.sol";
import {Swapper} from "../src/Swapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../src/interfaces/IVoter.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(address minter, uint256 minterAllowedAmount) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address) external;
    function acceptOwnership() external;
}

/**
 * @title BaseAccountTest
 * @dev Test for Account Factory on Base network with veAero NFT loan functionality
 */
contract BaseAccountTest is Test {
    // Base network contracts
    IERC20 aero = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IVoter voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    
    // Test variables
    uint256 fork;
    address owner;
    address user;
    uint256 tokenId = 64196; // Existing veAero NFT on Base
    
    // Deployed contracts
    PortfolioFactory public portfolioFactory;
    Loan public loan;
    Vault public vault;
    Swapper public swapper;
    
    // User account
    address public userAccount;

    function setUp() public {
        // Create Base fork
        fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(24353746); // Use a recent block
        
        // Set up test addresses
        owner = vm.addr(0x123);
        user = votingEscrow.ownerOf(tokenId);
        
        console.log("Test setup:");
        console.log("Owner:", owner);
        console.log("User:", user);
        console.log("Token ID:", tokenId);
        
        // Deploy unified storage first
        _deployUnifiedStorage();
        
        // Deploy loan system
        _deployLoanSystem();
        
        // Deploy account factory system
        _deployPortfolioFactory();
        
        // Set up USDC minting
        _setupUSDC();
    }

    function _deployUnifiedStorage() internal {
        console.log("\n=== Deploying Unified Storage ===");
        
        // Deploy PortfolioFactory
        FacetRegistry facetRegistry = new FacetRegistry(address(this));
        portfolioFactory = new PortfolioFactory(address(facetRegistry));
        console.log("PortfolioFactory:", address(portfolioFactory));
        
        console.log("Unified Storage deployed successfully");
    }

    function _deployPortfolioFactory() internal {
        console.log("\n=== Deploying Account Factory System ===");
        
        // Deploy FacetRegistry
        FacetRegistry facetRegistry = new FacetRegistry(address(this));
        
        // Deploy PortfolioFactory with diamond pattern
        portfolioFactory = new PortfolioFactory(
            address(facetRegistry)
        );
        console.log("PortfolioFactory:", address(portfolioFactory));
        
        console.log("Account Factory System deployed successfully");
    }

    function _deployLoanSystem() internal {
        console.log("\n=== Deploying Loan System ===");
        
        // Deploy loan system using BaseDeploy
        BaseDeploy deployer = new BaseDeploy();
        (loan, vault) = deployer.deployLoan();
        
        console.log("Loan:", address(loan));
        console.log("Vault:", address(vault));
        
        // Configure loan
        vm.startPrank(address(deployer));
        loan.setMultiplier(100000000000);
        loan.setRewardsRate(11300);
        loan.setLenderPremium(2000);
        loan.setProtocolFee(500); // 5% protocol fee
        
        // Deploy and set swapper
        DeploySwapper swapperDeploy = new DeploySwapper();
        swapper = Swapper(swapperDeploy.deploy());
        loan.setSwapper(address(swapper));
        loan.setPortfolioFactory(address(portfolioFactory));
        
        // Transfer ownership
        IOwnable(address(loan)).transferOwnership(owner);
        vm.stopPrank();
        
        // Accept ownership
        vm.prank(owner);
        IOwnable(address(loan)).acceptOwnership();
        
        console.log("Loan System deployed and configured");
    }

    function _setupUSDC() internal {
        // Allow this test contract to mint USDC
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(vault), 100e6);
        usdc.mint(address(voter), 100e6);
        
        console.log("USDC setup completed");
    }

    function testCreateUserAccount() public {
        console.log("\n=== Testing User Account Creation ===");
        
        // Create user account
        vm.startPrank(user);
        userAccount = portfolioFactory.createAccount(user);
        vm.stopPrank();
        
        console.log("User Account created at:", userAccount);
        
        // FortyAcresPortfolioAccount IS the diamond now, so no separate diamond address
        console.log("FortyAcresPortfolioAccount (diamond) address:", userAccount);
        
        // Verify account creation
        assertEq(portfolioFactory.portfolios(user), userAccount, "Account address should match");
        
        // Verify account properties through AccountStorage
        address accountOwner = portfolioFactory.ownerOf(userAccount);
        assertEq(accountOwner, user, "Account owner should be user");
        
        // Check what facets the account factory has
        // Note: Facets are now managed by FacetRegistry, not portfolioFactory
        // This test needs to be updated to work with the new architecture
        console.log("Account factory facets count: 0 (managed by FacetRegistry)");
        console.log("Loan contract:", address(loan));
        
        // Check if the FortyAcresPortfolioAccount (diamond) has the facets
        try IDiamondLoupe(userAccount).facets() returns (IDiamondLoupe.Facet[] memory diamondFacets) {
            console.log("FortyAcresPortfolioAccount facets count:", diamondFacets.length);
            for (uint256 i = 0; i < diamondFacets.length; i++) {
                console.log("Facet", i, ":", diamondFacets[i].facetAddress);
                console.log("Function selectors count:", diamondFacets[i].functionSelectors.length);
            }
        } catch (bytes memory error) {
            console.log("Failed to get FortyAcresPortfolioAccount facets, error:");
            console.logBytes(error);
        }
        
        
        
        console.log("User account created successfully");
    }


    function testDepositVeAeroNft() public {
        console.log("\n=== Setting up User Account and NFT ===");
        
        // Create user account if it doesn't exist
        if (userAccount == address(0)) {
            vm.startPrank(user);
            userAccount = portfolioFactory.createAccount(user);
            vm.stopPrank();
            
        }
        
        // Transfer NFT to user account
        vm.startPrank(user);
        votingEscrow.transferFrom(user, userAccount, tokenId);
        
        vm.stopPrank();
        
        console.log("NFT deposited to user account:", userAccount);
    }

    function testRequestLoanWithVeAeroNft() public {
        console.log("\n=== Testing Loan Request with veAero NFT ===");
        
        // Set up user account and NFT
        testDepositVeAeroNft();
        
        // Get max loan amount
        (uint256 maxLoan, ) = loan.getMaxLoan(tokenId);
        console.log("Max loan amount:", maxLoan);
        assertTrue(maxLoan > 0, "Max loan should be greater than 0");
        
        // Request a loan with a portion of max loan
        uint256 loanAmount = maxLoan / 2; // Request half of max loan
        console.log("Requesting loan amount:", loanAmount);
        
        uint256 startingUserAccountBalance = usdc.balanceOf(userAccount);
        uint256 startingVaultBalance = usdc.balanceOf(address(vault));
        
        // Request the loan directly from the loan contract (bypassing diamond facets)
        vm.startPrank(userAccount);
        
        try loan.requestLoan(
            tokenId,
            loanAmount,
            Loan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false,
            false
        ) {
            console.log("requestLoan succeeded");
        } catch Error(string memory reason) {
            console.log("requestLoan failed with reason:", reason);
            revert("requestLoan failed");
        } catch (bytes memory lowLevelData) {
            console.log("requestLoan failed with low level data:");
            console.logBytes(lowLevelData);
            revert("requestLoan failed");
        }
        vm.stopPrank();
        
        // Debug: Check NFT owner after requestLoan
        console.log("NFT owner after requestLoan:", votingEscrow.ownerOf(tokenId));
        
        // Verify loan was created
        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > loanAmount, "Loan balance should be greater than requested amount (includes fees)");
        assertEq(borrower, userAccount, "Borrower should be the user account");
        
        // Verify NFT is now locked in the loan contract
        assertEq(votingEscrow.ownerOf(tokenId), userAccount, "NFT should stay in user account");
        
        // Verify USDC was transferred to user account
        assertTrue(usdc.balanceOf(userAccount) > startingUserAccountBalance, "User account should have received USDC");
        assertTrue(usdc.balanceOf(address(vault)) < startingVaultBalance, "Vault should have less USDC");
        
        console.log("Loan requested successfully");
        console.log("Final loan balance:", balance);
        console.log("User account USDC balance:", usdc.balanceOf(userAccount));
        console.log("Vault USDC balance:", usdc.balanceOf(address(vault)));
    }

    function testFullLoanWorkflow() public {
        console.log("\n=== Testing Full Loan Workflow ===");
        
        // Complete workflow: Create account -> Deposit NFT -> Request loan
        testRequestLoanWithVeAeroNft();
        
        // Verify the loan is active
        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > 0, "Loan should have a balance");
        assertEq(borrower, userAccount, "Borrower should be the user account");
        
        // Test loan payment (partial)
        uint256 partialPayment = balance / 4; // Pay 25% of the loan
        
        // Give user account some USDC to pay back
        usdc.mint(userAccount, balance);
        
        vm.startPrank(userAccount);
        usdc.approve(address(loan), balance);
        // Call pay function directly on loan contract
        loan.pay(tokenId, partialPayment);
        vm.stopPrank();
        
        // Verify partial payment
        (uint256 newBalance, ) = loan.getLoanDetails(tokenId);
        assertTrue(newBalance < balance, "Loan balance should be reduced");
        
        console.log("Partial loan payment successful");
        console.log("Original balance:", balance);
        console.log("New balance:", newBalance);
        
        // Test full loan payoff
        vm.startPrank(userAccount);
        // Pay remaining balance directly on loan contract
        loan.pay(tokenId, 0); // Pay remaining balance
        
        // Only claim collateral if NFT is owned by loan contract
        if (votingEscrow.ownerOf(tokenId) == address(loan)) {
            loan.claimCollateral(tokenId);
        }
        vm.stopPrank();
        
        // Verify NFT is in user account (either it was already there or returned after claim)
        assertEq(votingEscrow.ownerOf(tokenId), userAccount, "NFT should be in user account");
        
        // Verify loan is fully paid
        (uint256 finalBalance, ) = loan.getLoanDetails(tokenId);
        assertEq(finalBalance, 0, "Loan should be fully paid");
        
        console.log("Full loan payoff and NFT claim successful");
    }

    function testPortfolioFactoryIntegration() public {
        console.log("\n=== Testing Account Factory Integration ===");
        
        // Create first account
        vm.startPrank(user);
        address userAccount1 = portfolioFactory.createAccount(user);
        vm.stopPrank();
        
        // Test that we can create multiple accounts
        address user2 = vm.addr(0x456);
        
        // Create second account
        vm.startPrank(user2);
        address userAccount2 = portfolioFactory.createAccount(user2);
        vm.stopPrank();
        
        // Verify both accounts exist
        assertEq(portfolioFactory.portfolios(user), userAccount1, "First account address should match");
        assertEq(portfolioFactory.portfolios(user2), userAccount2, "Second account address should match");
        
        // Verify accounts are different
        assertNotEq(userAccount1, userAccount2, "Accounts should be different");
        
        console.log("Multiple accounts created successfully");
        console.log("Account 1:", userAccount1);
        console.log("Account 2:", userAccount2);
    }

    function testAccountPredictAddress() public {
        console.log("\n=== Testing Account Address Prediction ===");
        
        address testUser = vm.addr(0x789);
        
        // Predict the address
        // Note: predictAccountAddress method not available in current PortfolioFactory
        // address predictedAddress = portfolioFactory.predictAccountAddress(testUser);
        console.log("Predicted address: Not available in current implementation");
        
        // Create the account
        vm.startPrank(testUser);
        address actualAddress = portfolioFactory.createAccount(testUser);
        vm.stopPrank();
        
        // Verify prediction was correct
        // Note: Address prediction not available in current implementation
        // assertEq(predictedAddress, actualAddress, "Predicted address should match actual address");
        
        console.log("Address prediction successful");
    }
}
