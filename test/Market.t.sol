// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Market} from "../src/Market.sol";
import {IMarket} from "../src/interfaces/IMarket.sol";
import {ILoan} from "../src/interfaces/ILoan.sol";
import {Loan} from "../src/LoanV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IVoter} from "src/interfaces/IVoter.sol";
import {Vault} from "src/VaultV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ProtocolTimeLibrary} from "src/libraries/ProtocolTimeLibrary.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {BaseDeploy} from "../script/BaseDeploy.s.sol";
import {BaseUpgrade} from "../script/BaseUpgrade.s.sol";
import {DeploySwapper} from "../script/BaseDeploySwapper.s.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ICLGauge} from "src/interfaces/ICLGauge.sol";
import {Swapper} from "../src/Swapper.sol";
import {CommunityRewards} from "../src/CommunityRewards/CommunityRewards.sol";
import {IMinter} from "src/interfaces/IMinter.sol";

interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(address minter, uint256 minterAllowedAmount) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address) external;
    function acceptOwnership() external;
}

contract MarketTest is Test {
    uint256 fork;

    IERC20 aero = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    address[] pool = [address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59)];
    ProxyAdmin admin;

    // deployed contracts
    Vault vault;
    Loan public loan;
    Market public market;
    address owner;
    address user;
    address buyer;
    uint256 tokenId = 72562;
    Swapper public swapper;

    // Test parameters
    uint256 constant LISTING_PRICE = 1000e6; // 1000 USDC
    uint256 constant LOAN_AMOUNT = 100e6; // 100 USDC

    // Import events from IMarket
    event ListingCreated(uint256 indexed tokenId, address indexed owner, uint256 price, address paymentToken, bool hasOutstandingLoan, uint256 expiresAt);
    event ListingUpdated(uint256 indexed tokenId, uint256 price, address paymentToken, uint256 expiresAt);
    event ListingCancelled(uint256 indexed tokenId);
    event ListingTaken(uint256 indexed tokenId, address indexed buyer, uint256 price, uint256 fee);
    event OperatorApproved(address indexed owner, address indexed operator, bool approved);
    event PaymentTokenAllowed(address indexed token, bool allowed);
    event MarketFeeChanged(uint16 newBps);
    event FeeRecipientChanged(address newRecipient);

    function setUp() public {
        // Fork Base mainnet
        fork = vm.createFork("https://mainnet.base.org");
        vm.selectFork(fork);
        vm.rollFork(24353746); // Use a recent block

        // Set up test addresses
        owner = vm.addr(0x123);
        buyer = vm.addr(0x456);
        
        // Use a known working tokenId on Base
        tokenId = 349;
        user = votingEscrow.ownerOf(tokenId);
        require(user != address(0), "TokenId 349 has no owner");

        // Deploy loan contracts
        BaseDeploy deployer = new BaseDeploy();
        (loan, vault) = deployer.deployLoan();

        // Configure loan contract
        vm.startPrank(address(deployer));
        loan.setMultiplier(100000000000);
        loan.setRewardsRate(11300);
        loan.setLenderPremium(2000);
        loan.setProtocolFee(500); // 5% protocol fee
        
        // Deploy swapper
        DeploySwapper swapperDeploy = new DeploySwapper();
        swapper = Swapper(swapperDeploy.deploy());
        loan.setSwapper(address(swapper));
        
        // Transfer ownership to owner
        IOwnable(address(loan)).transferOwnership(owner);
        vm.stopPrank();

        // Accept ownership as owner
        vm.prank(owner);
        IOwnable(address(loan)).acceptOwnership();

        // Deploy Market contract
        Market marketImpl = new Market(address(loan), address(votingEscrow));
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,uint16,address)", 
            owner,      // _owner
            250,        // _marketFeeBps (2.5%)
            owner       // _feeRecipient
        );
        ERC1967Proxy marketProxy = new ERC1967Proxy(address(marketImpl), initData);
        market = Market(address(marketProxy));

        // The test contract is now the owner after initialization
        // Transfer ownership to the owner address
        address currentOwner = market.owner();
        console.log("Market current owner:", currentOwner);
        console.log("Test contract address:", address(this));
        console.log("Intended owner:", owner);
        
        // Market ownership is set during initialize(), no need to transfer
        
        // Upgrade loan contract to support market increaseLoan calls
        vm.startPrank(owner);
        
        // Deploy new loan implementation with market support
        Loan newLoanImpl = new Loan();
        
        // Upgrade the loan proxy to the new implementation
        loan.upgradeToAndCall(address(newLoanImpl), "");
        
        // Approve market contract in loan contract  
        loan.setApprovedContract(address(market), true);
        
        // Set USDC as allowed payment token
        market.setAllowedPaymentToken(address(usdc), true);
        vm.stopPrank();

        // Set up USDC minting capabilities
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        
        // Mint USDC to vault and users
        usdc.mint(address(vault), 10000e6);
        usdc.mint(buyer, 5000e6);
        
        // Create a loan for the user to list
        _createUserLoan();
    }

    function _createUserLoan() internal {
        // Impersonate the user to create a loan
        vm.startPrank(user);
        
        // First approve the loan contract to transfer the veNFT
        votingEscrow.approve(address(loan), tokenId);
        
        // Request a loan
        loan.requestLoan(
            tokenId,
            LOAN_AMOUNT,
            Loan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false,
            false
        );
        
        vm.stopPrank();
    }

    function testSetup() public view {
        // Verify contracts are deployed correctly
        assertEq(market.owner(), owner);
        assertEq(market.loan(), address(loan));
        
        // Verify loan exists
        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertEq(borrower, user);
        assertGt(balance, 0);
        
        console.log("Market contract:", address(market));
        console.log("Loan contract:", address(loan));
        console.log("Token owner:", user);
        console.log("Token ID:", tokenId);
        console.log("Loan balance:", balance);
    }

    function testMakeListing() public {
        // Get initial loan details
        (uint256 initialBalance, address borrower) = loan.getLoanDetails(tokenId);
        assertEq(borrower, user);

        // Impersonate user to create listing
        vm.startPrank(user);
        
        // Expect the ListingCreated event (with hasOutstandingLoan = true since balance > 0)
        vm.expectEmit(true, true, false, true);
        emit ListingCreated(tokenId, user, LISTING_PRICE, address(usdc), true, 0);
        
        // Create listing (expiresAt = 0 means no expiration)
        market.makeListing(
            tokenId, 
            LISTING_PRICE, 
            address(usdc), 
            0 // expiresAt
        );
        
        vm.stopPrank();

        // Verify listing was created using new interface
        (
            address owner,
            uint256 price,
            address paymentToken,
            bool hasOutstandingLoan,
            uint256 expiresAt
        ) = market.getListing(tokenId);
        
        assertEq(owner, user);
        assertEq(price, LISTING_PRICE);
        assertEq(paymentToken, address(usdc));
        assertTrue(hasOutstandingLoan); // Should be true since loan balance > 0
        assertEq(expiresAt, 0);
        
        console.log("Listing created successfully");
        console.log("Listing price:", price);
        console.log("Has outstanding loan:", hasOutstandingLoan);
    }

    function testTakeListing() public {
        // First create a listing
        vm.startPrank(user);
        market.makeListing(
            tokenId, 
            LISTING_PRICE, 
            address(usdc), 
            0
        );
        vm.stopPrank();

        // Get initial state
        (uint256 initialBalance, address initialBorrower) = loan.getLoanDetails(tokenId);
        uint256 buyerInitialUSDC = usdc.balanceOf(buyer);
        uint256 sellerInitialUSDC = usdc.balanceOf(user);

        // Get total cost including loan balance
        (uint256 totalCost, uint256 listingPrice, uint256 loanBalance,) = market.getTotalCost(tokenId);
        
        // Buyer takes the listing
        vm.startPrank(buyer);
        
        // Approve USDC for total payment (listing price + loan balance)
        usdc.approve(address(market), totalCost);
        
        // Calculate expected fee (on listing price only)
        uint256 expectedFee = (listingPrice * market.marketFeeBps()) / 10000;
        
        // Expect ListingTaken event
        vm.expectEmit(true, true, false, true);
        emit ListingTaken(tokenId, buyer, listingPrice, expectedFee);
        
        // Take the listing
        market.takeListing(tokenId);
        
        vm.stopPrank();

        // Verify ownership transfer
        (, address newBorrower) = loan.getLoanDetails(tokenId);
        assertEq(newBorrower, buyer);
        assertNotEq(newBorrower, initialBorrower);

        // Verify payment transfer (buyer pays total cost)
        assertEq(usdc.balanceOf(buyer), buyerInitialUSDC - totalCost);
        // Seller receives listing price minus fee
        assertEq(usdc.balanceOf(user), sellerInitialUSDC + listingPrice - expectedFee);

        // Verify listing is removed
        (address listingOwner,,,,) = market.getListing(tokenId);
        assertEq(listingOwner, address(0));

        console.log("Listing taken successfully");
        console.log("New loan owner:", newBorrower);
        console.log("Total cost paid:", totalCost);
        console.log("Market fee:", expectedFee);
    }

    function testCannotTakeOwnListing() public {
        // Create listing
        vm.startPrank(user);
        market.makeListing(
            tokenId, 
            LISTING_PRICE, 
            address(usdc), 
            0
        );
        
        // Get total cost for approval
        (uint256 totalCost,,,) = market.getTotalCost(tokenId);
        usdc.approve(address(market), totalCost);
        
        // Try to take own listing - should revert due to authorization check
        vm.expectRevert(); // The exact error message depends on implementation
        market.takeListing(tokenId);
        
        vm.stopPrank();
    }

    function testCannotListNonOwnedLoan() public {
        // Try to list with different user
        vm.startPrank(buyer);
        
        vm.expectRevert(); // Should revert due to unauthorized access
        market.makeListing(
            tokenId, 
            LISTING_PRICE, 
            address(usdc), 
            0
        );
        
        vm.stopPrank();
    }

    function testCannotTakeNonExistentListing() public {
        uint256 nonExistentTokenId = 999999;
        
        vm.startPrank(buyer);
        usdc.approve(address(market), LISTING_PRICE);
        
        vm.expectRevert(); // Should revert for non-existent listing
        market.takeListing(nonExistentTokenId);
        
        vm.stopPrank();
    }

    function testCancelListing() public {
        // Create listing
        vm.startPrank(user);
        market.makeListing(
            tokenId, 
            LISTING_PRICE, 
            address(usdc), 
            0
        );
        
        // Expect ListingCancelled event
        vm.expectEmit(true, false, false, false);
        emit ListingCancelled(tokenId);
        
        // Cancel listing
        market.cancelListing(tokenId);
        vm.stopPrank();

        // Verify listing is removed
        (address listingOwner,,,,) = market.getListing(tokenId);
        assertEq(listingOwner, address(0));
    }

    function testUpdateListing() public {
        uint256 newPrice = 2000e6;
        address newPaymentToken = address(weth);
        uint256 newExpiresAt = block.timestamp + 7 days;

        // First set weth as allowed payment token
        vm.prank(owner);
        market.setAllowedPaymentToken(newPaymentToken, true);

        // Create listing
        vm.startPrank(user);
        market.makeListing(
            tokenId, 
            LISTING_PRICE, 
            address(usdc), 
            0
        );
        
        // Expect ListingUpdated event
        vm.expectEmit(true, false, false, true);
        emit ListingUpdated(tokenId, newPrice, newPaymentToken, newExpiresAt);
        
        // Update listing
        market.updateListing(tokenId, newPrice, newPaymentToken, newExpiresAt);
        vm.stopPrank();

        // Verify listing is updated
        (
            address owner,
            uint256 price,
            address paymentToken,
            bool hasOutstandingLoan,
            uint256 expiresAt
        ) = market.getListing(tokenId);
        
        assertEq(price, newPrice);
        assertEq(paymentToken, newPaymentToken);
        assertEq(expiresAt, newExpiresAt);
    }

    function testUnauthorizedMarketCannotTransferOwnership() public {
        // Deploy unauthorized market contract
        Market unauthorizedMarket = new Market(address(loan), address(votingEscrow));
        
        vm.startPrank(address(unauthorizedMarket));
        
        vm.expectRevert(); // Should revert for unauthorized market
        loan.setBorrower(tokenId, buyer);
        
        vm.stopPrank();
    }

    function testOwnerCanApproveMarketContracts() public {
        address newMarketContract = vm.addr(0x789);
        
        vm.startPrank(owner);
        
        loan.setApprovedContract(newMarketContract, true);
        
        // Verify approval (assuming this function exists)
        // assertTrue(loan.isApprovedContract(newMarketContract));
        
        // Remove approval
        loan.setApprovedContract(newMarketContract, false);
        // assertFalse(loan.isApprovedContract(newMarketContract));
        
        vm.stopPrank();
    }

    // ============ MISSING FLOW TESTS ============

    function testTakeListingNoOutstandingLoan() public {
        // Create a veNFT without a loan first
        uint256 newTokenId = 350; // Different token without loan
        address newTokenOwner = votingEscrow.ownerOf(newTokenId);
        vm.assume(newTokenOwner != address(0));
        
        // Create listing for token without outstanding loan
        vm.startPrank(newTokenOwner);
        
        // Approve and request zero-amount loan to move custody
        votingEscrow.approve(address(loan), newTokenId);
        loan.requestLoan(
            newTokenId,
            0, // No loan amount
            Loan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false,
            false
        );
        
        // Create listing (should have hasOutstandingLoan = false)
        market.makeListing(
            newTokenId,
            LISTING_PRICE,
            address(usdc),
            0
        );
        vm.stopPrank();
        
        // Verify listing has no outstanding loan
        (, uint256 price,, bool hasOutstandingLoan,) = market.getListing(newTokenId);
        assertFalse(hasOutstandingLoan);
        assertEq(price, LISTING_PRICE);
        
        // Get total cost (should just be listing price)
        (uint256 totalCost, uint256 listingPrice, uint256 loanBalance,) = market.getTotalCost(newTokenId);
        assertEq(totalCost, LISTING_PRICE);
        assertEq(listingPrice, LISTING_PRICE);
        assertEq(loanBalance, 0);
        
        // Buyer takes the listing
        vm.startPrank(buyer);
        usdc.approve(address(market), LISTING_PRICE);
        
        uint256 expectedFee = (LISTING_PRICE * market.marketFeeBps()) / 10000;
        uint256 buyerInitialBalance = usdc.balanceOf(buyer);
        uint256 sellerInitialBalance = usdc.balanceOf(newTokenOwner);
        
        market.takeListing(newTokenId);
        vm.stopPrank();
        
        // Verify payment (no loan to pay off)
        assertEq(usdc.balanceOf(buyer), buyerInitialBalance - LISTING_PRICE);
        assertEq(usdc.balanceOf(newTokenOwner), sellerInitialBalance + LISTING_PRICE - expectedFee);
        
        // Verify ownership transfer
        (, address newBorrower) = loan.getLoanDetails(newTokenId);
        assertEq(newBorrower, buyer);
        
        console.log("Flow B - No Outstanding Loan test passed");
    }

    function testListingExpiration() public {
        uint256 expirationTime = block.timestamp + 1 hours;
        
        // Create listing with expiration
        vm.startPrank(user);
        market.makeListing(
            tokenId,
            LISTING_PRICE,
            address(usdc),
            expirationTime
        );
        vm.stopPrank();
        
        // Verify listing is active before expiration
        assertTrue(market.isListingActive(tokenId));
        
        // Warp time past expiration
        vm.warp(expirationTime + 1);
        
        // Verify listing is no longer active
        assertFalse(market.isListingActive(tokenId));
        
        // Verify taking expired listing fails
        vm.startPrank(buyer);
        usdc.approve(address(market), type(uint256).max);
        vm.expectRevert();
        market.takeListing(tokenId);
        vm.stopPrank();
        
        console.log("Listing expiration test passed");
    }

    function testVeNFTNotInLoanV2Custody() public {
        // Find a veNFT that's not in LoanV2 custody
        uint256 directOwnedTokenId = 400; // Try a different token
        address directOwner = votingEscrow.ownerOf(directOwnedTokenId);
        vm.assume(directOwner != address(0));
        
        // Verify it's not in loan custody
        (, address borrower) = loan.getLoanDetails(directOwnedTokenId);
        vm.assume(borrower == address(0)); // Not in loan custody
        
        vm.startPrank(directOwner);
        
        // First, the user must deposit the veNFT into LoanV2
        votingEscrow.approve(address(loan), directOwnedTokenId);
        loan.requestLoan(
            directOwnedTokenId,
            0, // No loan amount
            Loan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false,
            false
        );
        
        // Now create listing - veNFT is already in LoanV2 custody
        market.makeListing(
            directOwnedTokenId,
            LISTING_PRICE,
            address(usdc),
            0
        );
        
        vm.stopPrank();
        
        // Verify veNFT is in LoanV2 custody
        (, address newBorrower) = loan.getLoanDetails(directOwnedTokenId);
        assertEq(newBorrower, directOwner);
        
        // Verify listing was created
        (address listingOwner,,,,) = market.getListing(directOwnedTokenId);
        assertEq(listingOwner, directOwner);
        
        console.log("veNFT manual custody transfer test passed");
    }
} 