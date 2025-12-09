// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {DiamondMarketTestBase} from "../utils/DiamondMarketTestBase.t.sol";

// Portfolio imports
import {PortfolioFactory} from "src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "src/accounts/FacetRegistry.sol";
import {MarketplaceFacet} from "src/facets/account/marketplace/MarketplaceFacet.sol";
import {AccountConfigStorage} from "src/storage/AccountConfigStorage.sol";

// Market interfaces
import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {IMarketViewFacet} from "src/interfaces/IMarketViewFacet.sol";
import {IMarketListingsLoanFacet} from "src/interfaces/IMarketListingsLoanFacet.sol";
import {IPortfolioMarketplaceFacet} from "src/interfaces/IPortfolioMarketplaceFacet.sol";
import {RouteLib} from "src/libraries/RouteLib.sol";

// Core imports
import {ILoan} from "src/interfaces/ILoan.sol";
import {Loan} from "src/LoanV2.sol";
import {Vault} from "src/VaultV2.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface IUSDC_PL {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(address minter, uint256 minterAllowedAmount) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/**
 * @title PortfolioLoanListingsTest
 * @dev Tests for marketplace listings with portfolio-held veNFTs
 */
contract PortfolioLoanListingsTest is DiamondMarketTestBase {
    // Base network contracts
    IERC20 aero = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
    IUSDC_PL usdc = IUSDC_PL(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);

    // Portfolio infrastructure
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    AccountConfigStorage public accountConfigStorage;
    MarketplaceFacet public marketplaceFacet;

    // Loan infrastructure
    Loan public loan;
    Vault public vault;

    // Test addresses
    address public seller;
    address public buyer;
    address public sellerPortfolio;
    address public feeRecipient;

    // Test token
    uint256 public tokenId = 65424;

    // Constants
    uint256 constant LISTING_PRICE = 1000e6; // 1000 USDC

    function setUp() public {
        // Fork Base mainnet
        uint256 fork = vm.createFork("https://mainnet.base.org");
        vm.selectFork(fork);
        vm.rollFork(34683000);

        // Get existing veNFT owner as seller
        seller = votingEscrow.ownerOf(tokenId);
        buyer = vm.addr(0x456);
        feeRecipient = address(this);

        // Deploy market diamond
        _deployDiamondAndFacets();

        // Upgrade canonical loan for market support
        loan = Loan(BASE_LOAN_CANONICAL);
        upgradeCanonicalLoan();

        // Deploy portfolio infrastructure
        _deployPortfolioInfrastructure();

        // Initialize market with portfolio factory
        _initMarketWithPortfolio();

        // Setup USDC minting
        _setupUSDC();

        console.log("=== Test Setup Complete ===");
        console.log("Seller:", seller);
        console.log("Buyer:", buyer);
        console.log("Token ID:", tokenId);
        console.log("Market Diamond:", diamond);
        console.log("Portfolio Factory:", address(portfolioFactory));
    }

    function _deployPortfolioInfrastructure() internal {
        console.log("\n=== Deploying Portfolio Infrastructure ===");

        // Deploy AccountConfigStorage behind a proxy
        AccountConfigStorage impl = new AccountConfigStorage();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(AccountConfigStorage.initialize.selector)
        );
        accountConfigStorage = AccountConfigStorage(address(proxy));

        // Deploy FacetRegistry
        facetRegistry = new FacetRegistry(address(this));

        // Deploy PortfolioFactory
        portfolioFactory = new PortfolioFactory(address(facetRegistry));

        // Deploy MarketplaceFacet with required immutables
        marketplaceFacet = new MarketplaceFacet(
            address(portfolioFactory),
            address(accountConfigStorage),
            address(votingEscrow),
            address(loan),
            diamond // market diamond
        );

        // Register MarketplaceFacet in FacetRegistry
        bytes4[] memory marketplaceSelectors = new bytes4[](5);
        marketplaceSelectors[0] = IPortfolioMarketplaceFacet.finalizeMarketPurchase.selector;
        marketplaceSelectors[1] = IPortfolioMarketplaceFacet.finalizeOfferPurchase.selector;
        marketplaceSelectors[2] = IPortfolioMarketplaceFacet.finalizeLBOPurchase.selector;
        marketplaceSelectors[3] = IPortfolioMarketplaceFacet.receiveMarketPurchase.selector;
        marketplaceSelectors[4] = IPortfolioMarketplaceFacet.getPortfolioOwner.selector;

        facetRegistry.registerFacet(
            address(marketplaceFacet),
            marketplaceSelectors,
            "MarketplaceFacet"
        );

        // Configure AccountConfigStorage
        accountConfigStorage.setLoanContract(address(loan));
        accountConfigStorage.setApprovedContract(diamond, true);

        console.log("AccountConfigStorage:", address(accountConfigStorage));
        console.log("FacetRegistry:", address(facetRegistry));
        console.log("MarketplaceFacet:", address(marketplaceFacet));
        console.log("Portfolio infrastructure deployed");
    }

    function _initMarketWithPortfolio() internal {
        // Set portfolio factory in loan contract first (required for initMarket)
        address loanOwner = loan.owner();
        vm.prank(loanOwner);
        loan.setPortfolioFactory(address(portfolioFactory));
        
        // Initialize market diamond with portfolio factory
        IMarketConfigFacet(diamond).initMarket(
            address(loan),
            address(votingEscrow),
            100, // 1% base fee
            200, // 2% external fee
            100, // 1% LBO lender fee
            100, // 1% LBO protocol fee
            feeRecipient,
            address(usdc)
        );

        console.log("Market initialized with portfolio factory");
        console.log("Portfolio factory from loan:", loan.getPortfolioFactory());
    }

    function _setupUSDC() internal {
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        
        // Fund buyer
        usdc.mint(buyer, 10000e6);
        
        // Fund vault for loan operations
        vault = Vault(loan._vault());
        usdc.mint(address(vault), 100000e6);
        
        console.log("USDC setup complete");
    }

    function _createSellerPortfolio() internal returns (address) {
        vm.prank(seller);
        sellerPortfolio = portfolioFactory.createAccount(seller);
        console.log("Seller portfolio created:", sellerPortfolio);
        return sellerPortfolio;
    }

    function _depositVeNFTToPortfolio() internal {
        vm.startPrank(seller);
        votingEscrow.transferFrom(seller, sellerPortfolio, tokenId);
        vm.stopPrank();
        
        assertEq(votingEscrow.ownerOf(tokenId), sellerPortfolio, "NFT should be in portfolio");
        console.log("veNFT deposited to portfolio");
    }

    // ============ Tests ============

    function test_setup() public view {
        // Verify basic setup
        assertTrue(diamond != address(0), "Diamond should be deployed");
        assertTrue(address(portfolioFactory) != address(0), "PortfolioFactory should be deployed");
        assertTrue(address(facetRegistry) != address(0), "FacetRegistry should be deployed");
        assertTrue(facetRegistry.isFacetRegistered(address(marketplaceFacet)), "MarketplaceFacet should be registered");
        
        console.log("Setup verification passed");
    }

    function test_createPortfolioAndDeposit() public {
        // Create portfolio
        _createSellerPortfolio();
        
        // Verify portfolio
        assertEq(portfolioFactory.portfolioOf(seller), sellerPortfolio, "Portfolio should be linked to seller");
        assertEq(portfolioFactory.ownerOf(sellerPortfolio), seller, "Seller should own portfolio");
        
        // Deposit NFT
        _depositVeNFTToPortfolio();
        
        // Verify deposit
        assertEq(votingEscrow.ownerOf(tokenId), sellerPortfolio, "NFT should be in portfolio");
        
        console.log("Portfolio creation and deposit test passed");
    }

    function test_makeLoanListing_fromPortfolio() public {
        // Setup: create portfolio and deposit NFT
        _createSellerPortfolio();
        _depositVeNFTToPortfolio();

        // Create listing as portfolio owner (seller EOA)
        vm.prank(seller);
        IMarketListingsLoanFacet(diamond).makeLoanListing(
            tokenId,
            LISTING_PRICE,
            address(usdc),
            0, // no expiration
            address(0) // no buyer restriction
        );

        // Verify listing created
        (
            address listingOwner,
            uint256 price,
            address paymentToken,
            bool hasOutstandingLoan,
            uint256 expiresAt
        ) = IMarketViewFacet(diamond).getListing(tokenId);

        assertEq(listingOwner, sellerPortfolio, "Listing owner should be portfolio");
        assertEq(price, LISTING_PRICE, "Price should match");
        assertEq(paymentToken, address(usdc), "Payment token should be USDC");
        assertFalse(hasOutstandingLoan, "Should not have outstanding loan");
        assertEq(expiresAt, 0, "Should not expire");

        console.log("Loan listing from portfolio test passed");
    }

    function test_updateLoanListing_asPortfolioOwner() public {
        // Setup: create portfolio, deposit NFT, create listing
        _createSellerPortfolio();
        _depositVeNFTToPortfolio();

        vm.prank(seller);
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, LISTING_PRICE, address(usdc), 0, address(0));

        // Update listing as portfolio owner
        uint256 newPrice = 2000e6;
        vm.prank(seller);
        IMarketListingsLoanFacet(diamond).updateLoanListing(tokenId, newPrice, address(usdc), 0, address(0));

        // Verify update
        (, uint256 price,,,) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(price, newPrice, "Price should be updated");

        console.log("Update listing test passed");
    }

    function test_cancelLoanListing_asPortfolioOwner() public {
        // Setup: create portfolio, deposit NFT, create listing
        _createSellerPortfolio();
        _depositVeNFTToPortfolio();

        vm.prank(seller);
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, LISTING_PRICE, address(usdc), 0, address(0));

        // Cancel listing as portfolio owner
        vm.prank(seller);
        IMarketListingsLoanFacet(diamond).cancelLoanListing(tokenId);

        // Verify cancellation
        (address listingOwner,,,,) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(listingOwner, address(0), "Listing should be cancelled");

        console.log("Cancel listing test passed");
    }

    function test_takeLoanListing_transfersTobuyer() public {
        // Setup: create portfolio, deposit NFT, create listing
        _createSellerPortfolio();
        _depositVeNFTToPortfolio();

        vm.prank(seller);
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, LISTING_PRICE, address(usdc), 0, address(0));

        // Record balances before
        uint256 sellerBalanceBefore = usdc.balanceOf(sellerPortfolio);
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        // Buyer takes listing
        vm.startPrank(buyer);
        IERC20(address(usdc)).approve(diamond, LISTING_PRICE);
        IMarketListingsLoanFacet(diamond).takeLoanListing(
            tokenId,
            address(usdc),
            0,
            bytes(""),
            bytes("")
        );
        vm.stopPrank();

        // Verify NFT transferred to buyer
        assertEq(votingEscrow.ownerOf(tokenId), buyer, "NFT should be transferred to buyer");

        // Verify payment distribution
        uint256 expectedFee = (LISTING_PRICE * 100) / 10000; // 1%
        uint256 sellerReceived = usdc.balanceOf(sellerPortfolio) - sellerBalanceBefore;
        uint256 feeReceived = usdc.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        uint256 buyerSpent = buyerBalanceBefore - usdc.balanceOf(buyer);

        assertEq(sellerReceived, LISTING_PRICE - expectedFee, "Seller should receive price minus fee");
        assertEq(feeReceived, expectedFee, "Fee recipient should receive fee");
        assertEq(buyerSpent, LISTING_PRICE, "Buyer should spend listing price");

        // Verify listing deleted
        (address listingOwner,,,,) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(listingOwner, address(0), "Listing should be deleted");

        console.log("Take listing test passed");
        console.log("Seller received:", sellerReceived);
        console.log("Fee received:", feeReceived);
        console.log("Buyer spent:", buyerSpent);
    }

    function test_revert_makeListing_notPortfolioOwner() public {
        // Setup: create portfolio and deposit NFT
        _createSellerPortfolio();
        _depositVeNFTToPortfolio();

        // Try to create listing as non-owner (buyer)
        vm.prank(buyer);
        vm.expectRevert();
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, LISTING_PRICE, address(usdc), 0, address(0));

        console.log("Unauthorized listing revert test passed");
    }

    function test_revert_makeListing_notInPortfolio() public {
        // Try to create listing for NFT not in a portfolio (still in seller wallet)
        vm.prank(seller);
        vm.expectRevert(); // Should revert with BadCustody
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, LISTING_PRICE, address(usdc), 0, address(0));

        console.log("Not in portfolio revert test passed");
    }

    function test_canOperate_portfolioOwner() public {
        // Setup: create portfolio
        _createSellerPortfolio();

        // Test canOperate via view function
        bool canOperate = IMarketViewFacet(diamond).canOperate(sellerPortfolio, seller);
        assertTrue(canOperate, "Portfolio owner should be able to operate");

        bool cannotOperate = IMarketViewFacet(diamond).canOperate(sellerPortfolio, buyer);
        assertFalse(cannotOperate, "Non-owner should not be able to operate");

        console.log("canOperate test passed");
    }
}

