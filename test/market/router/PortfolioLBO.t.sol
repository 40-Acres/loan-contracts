// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DiamondMarketTestBase} from "../../utils/DiamondMarketTestBase.t.sol";
import {IMarketRouterFacet} from "src/interfaces/IMarketRouterFacet.sol";
import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {IMarketViewFacet} from "src/interfaces/IMarketViewFacet.sol";
import {IMarketListingsLoanFacet} from "src/interfaces/IMarketListingsLoanFacet.sol";
import {IMarketListingsWalletFacet} from "src/interfaces/IMarketListingsWalletFacet.sol";
import {IPortfolioMarketplaceFacet} from "src/interfaces/IPortfolioMarketplaceFacet.sol";
import "forge-std/console.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {RouteLib} from "src/libraries/RouteLib.sol";
import {Loan} from "src/LoanV2.sol";
import {Vault} from "src/VaultV2.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ILoan} from "src/interfaces/ILoan.sol";

// Portfolio imports
import {PortfolioFactory} from "src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "src/accounts/FacetRegistry.sol";
import {MarketplaceFacet} from "src/facets/account/marketplace/MarketplaceFacet.sol";
import {PortfolioAccountConfig} from "src/facets/account/config/PortfolioAccountConfig.sol";
import {LoanConfig} from "src/facets/account/config/LoanConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface IOwnableMinimal_PL { function owner() external view returns (address); }

interface IUSDC_PL {
    function configureMinter(address, uint256) external;
    function masterMinter() external view returns (address);
    function mint(address, uint256) external;
}

interface ILoanReq {
    function requestLoan(uint256 tokenId, uint256 amount, uint8 zeroBalOption, uint256 rate, address ref, bool a, bool b) external;
    function getLoanDetails(uint256 tokenId) external view returns (uint256 balance, address borrower);
}

contract MockOdosRouterPL {
    address public testContract;
    function initMock(address _testContract) external { testContract = _testContract; }
    
    // Multi-input swap for LBO: takes AERO from caller, receives USDC from contract, outputs USDC to caller
    function executeMultiInputSwap(address tokenIn, uint256 amountIn, uint256 usdcFromContract, uint256 totalUsdcOut) external returns (bool) {
        address usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        // Take AERO from caller
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        // Take USDC from caller (flash loan amount)
        IERC20(usdc).transferFrom(msg.sender, address(this), usdcFromContract);
        // Mint total USDC output to caller
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", IUSDC_PL(usdc).masterMinter(), msg.sender, totalUsdcOut));
        require(success, "mint fail");
        return true;
    }
}

contract PortfolioLBOTest is DiamondMarketTestBase {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant ODOS = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;
    address constant VE = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address constant LOAN_CANONICAL = 0x87f18b377e625b62c708D5f6EA96EC193558EFD0;
    
    Loan public loan;
    Vault public vault;

    // Portfolio infrastructure
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioAccountConfig public portfolioAccountConfig;
    LoanConfig public loanConfig;
    MarketplaceFacet public marketplaceFacet;

    address seller;
    address buyer;
    address buyerPortfolio;
    address feeRecipient;

    function setUp() public {
        uint256 fork = vm.createFork("https://mainnet.base.org");
        vm.selectFork(fork);
        vm.rollFork(34683000);

        _deployDiamondAndFacets();

        feeRecipient = IOwnableMinimal_PL(LOAN_CANONICAL).owner();
        upgradeCanonicalLoan();
        
        loan = Loan(LOAN_CANONICAL);

        // Deploy portfolio infrastructure
        _deployPortfolioInfrastructure();

        // Initialize market with portfolio factory
        _initMarketWithPortfolio();

        IMarketConfigFacet(diamond).setAllowedPaymentToken(USDC, true);
        IMarketConfigFacet(diamond).setAllowedPaymentToken(AERO, true);

        // Internal=1% (100 bps), External=2% (200 bps)
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.InternalWallet, 100);
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.InternalLoan, 100);
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.ExternalAdapter, 200);

        // USDC minting for tests and mock Odos setup at canonical address
        vm.prank(IUSDC_PL(USDC).masterMinter());
        IUSDC_PL(USDC).configureMinter(address(this), type(uint256).max);
        MockOdosRouterPL mock = new MockOdosRouterPL();
        bytes memory code = address(mock).code;
        vm.etch(ODOS, code);
        MockOdosRouterPL(ODOS).initMock(address(this));
    }

    function _deployPortfolioInfrastructure() internal {
        console.log("\n=== Deploying Portfolio Infrastructure ===");

        // Deploy LoanConfig behind a proxy
        LoanConfig loanConfigImpl = new LoanConfig();
        ERC1967Proxy loanConfigProxy = new ERC1967Proxy(
            address(loanConfigImpl),
            abi.encodeWithSelector(LoanConfig.initialize.selector, address(this))
        );
        loanConfig = LoanConfig(address(loanConfigProxy));
        
        // Configure LoanConfig with values from the canonical loan
        loanConfig.setRewardsRate(loan.getRewardsRate());
        loanConfig.setMultiplier(loan.getMultiplier());

        // Deploy PortfolioAccountConfig behind a proxy
        PortfolioAccountConfig configImpl = new PortfolioAccountConfig();
        ERC1967Proxy configProxy = new ERC1967Proxy(
            address(configImpl),
            abi.encodeWithSelector(PortfolioAccountConfig.initialize.selector, address(this))
        );
        portfolioAccountConfig = PortfolioAccountConfig(address(configProxy));

        // Deploy FacetRegistry
        facetRegistry = new FacetRegistry(address(this));

        // Deploy PortfolioFactory
        portfolioFactory = new PortfolioFactory(address(facetRegistry));

        // Deploy MarketplaceFacet with required immutables
        marketplaceFacet = new MarketplaceFacet(
            address(portfolioFactory),
            address(portfolioAccountConfig),
            VE,
            address(loan),
            diamond // market diamond
        );

        // Register MarketplaceFacet in FacetRegistry - include LBO functions
        bytes4[] memory marketplaceSelectors = new bytes4[](8);
        marketplaceSelectors[0] = IPortfolioMarketplaceFacet.finalizeMarketPurchase.selector;
        marketplaceSelectors[1] = IPortfolioMarketplaceFacet.finalizeOfferPurchase.selector;
        marketplaceSelectors[2] = IPortfolioMarketplaceFacet.finalizeLBOPurchase.selector;
        marketplaceSelectors[3] = IPortfolioMarketplaceFacet.receiveMarketPurchase.selector;
        marketplaceSelectors[4] = IPortfolioMarketplaceFacet.getPortfolioOwner.selector;
        marketplaceSelectors[5] = IPortfolioMarketplaceFacet.ownsVeNFT.selector;
        marketplaceSelectors[6] = IPortfolioMarketplaceFacet.executeLBO.selector;
        marketplaceSelectors[7] = IPortfolioMarketplaceFacet.onFlashLoan.selector;

        facetRegistry.registerFacet(
            address(marketplaceFacet),
            marketplaceSelectors,
            "MarketplaceFacet"
        );

        // Configure PortfolioAccountConfig
        portfolioAccountConfig.setLoanContract(address(loan));
        portfolioAccountConfig.setLoanConfig(address(loanConfig));
        portfolioAccountConfig.setApprovedContract(diamond, true);
        portfolioAccountConfig.setApprovedContract(address(loan), true);

        console.log("LoanConfig:", address(loanConfig));
        console.log("PortfolioAccountConfig:", address(portfolioAccountConfig));
        console.log("FacetRegistry:", address(facetRegistry));
        console.log("MarketplaceFacet:", address(marketplaceFacet));
        console.log("Portfolio infrastructure deployed");
    }

    function _initMarketWithPortfolio() internal {
        // Set portfolio factory in loan contract first
        address loanOwner = loan.owner();
        vm.prank(loanOwner);
        loan.setPortfolioFactory(address(portfolioFactory));
        
        // Initialize market diamond
        _initMarket(address(loan), VE, 100, 200, 100, 100, feeRecipient, USDC);

        console.log("Market initialized with portfolio factory");
        console.log("Portfolio factory from loan:", loan.getPortfolioFactory());
    }

    function _createBuyerPortfolio() internal returns (address) {
        vm.prank(buyer);
        buyerPortfolio = portfolioFactory.createAccount(buyer);
        console.log("Buyer portfolio created:", buyerPortfolio);
        return buyerPortfolio;
    }

    // helper for mock to mint USDC to a recipient
    function mintUsdc(address /*minter*/, address to, uint256 amount) external {
        IUSDC_PL(USDC).mint(to, amount);
    }

    function test_success_portfolioLBO_AEROInput_USDCListing() public {
        uint256 tokenId = 65424;
        IVotingEscrow ve = IVotingEscrow(VE);
        seller = ve.ownerOf(tokenId);
        vm.assume(seller != address(0));

        // Create a wallet listing (NFT not in loan custody yet) in USDC
        vm.startPrank(seller);
        uint256 listingPrice = 35_000e6; // $35000 USDC
        ve.approve(diamond, tokenId);
        IMarketListingsWalletFacet(diamond).makeWalletListing(tokenId, listingPrice, USDC, 0, address(0));
        vm.stopPrank();

        // LBO buyer setup - MUST CREATE PORTFOLIO FIRST
        buyer = vm.addr(0x1234);
        uint256 userAeroAmount = 22000e18; // 22000 AERO (~$28000 or 80% of listing price)
        deal(AERO, buyer, userAeroAmount);

        // Create buyer's portfolio account
        _createBuyerPortfolio();

        // Get the actual max loan amount for this real veNFT 
        (uint256 maxLoanPossible,) = ILoan(address(loan)).getMaxLoan(tokenId);
        console.log("Real veNFT max loan possible:", maxLoanPossible);
        
        // Calculate expected amounts
        uint256 upfrontProtocolFee = (listingPrice * IMarketViewFacet(diamond).getLBOProtocolFeeBps()) / 10000;
        uint256 totalNeeded = listingPrice + upfrontProtocolFee;

        // Build trade data for AERO + USDC -> USDC swap
        bytes memory lboTradeData = abi.encodeWithSelector(
            MockOdosRouterPL.executeMultiInputSwap.selector,
            AERO,
            userAeroAmount,
            maxLoanPossible, // USDC from flash loan
            totalNeeded // Output enough USDC for listing + upfront fee
        );
        
        console.log("=== Portfolio LBO Test Setup ===");
        console.log("Listing price:", listingPrice);
        console.log("User AERO amount:", userAeroAmount);
        console.log("Flash loan amount (max loan):", maxLoanPossible);
        console.log("Total needed:", totalNeeded);
        console.log("Buyer portfolio:", buyerPortfolio);

        // Record balances before
        uint256 usdcSellerBefore = IERC20(USDC).balanceOf(seller);
        uint256 aeroBuyerBefore = IERC20(AERO).balanceOf(buyer);

        // Execute LBO via buyer's portfolio
        vm.startPrank(buyer);
        IERC20(AERO).approve(buyerPortfolio, userAeroAmount);
        
        IPortfolioMarketplaceFacet(buyerPortfolio).executeLBO(
            tokenId,
            RouteLib.BuyRoute.InternalWallet,
            bytes32(0), // adapterKey
            USDC, // inputAsset (after swap, we'll have USDC)
            listingPrice, // maxPaymentTotal
            AERO, // userPaymentAsset
            userAeroAmount, // userPaymentAmount
            bytes(""), // purchaseTradeData (empty since buyToken won't need to swap)
            lboTradeData, // lboTradeData for AERO + USDC -> USDC swap
            bytes("") // marketData
        );
        vm.stopPrank();

        // Verify loan was created with buyer's PORTFOLIO as borrower
        (uint256 loanBalance, address borrower) = ILoanReq(address(loan)).getLoanDetails(tokenId);
        assertEq(borrower, buyerPortfolio, "Borrower should be buyer's portfolio");
        assertTrue(loanBalance > 0, "Should have loan balance from LBO");

        console.log("=== Portfolio LBO Results ===");
        console.log("- Loan Balance:", loanBalance);
        console.log("- Borrower (portfolio):", borrower);
        console.log("- NFT Owner:", ve.ownerOf(tokenId));
        console.log("- Seller USDC received:", IERC20(USDC).balanceOf(seller) - usdcSellerBefore);
        console.log("- Buyer AERO spent:", aeroBuyerBefore - IERC20(AERO).balanceOf(buyer));

        // Verify NFT is in loan custody (not in portfolio directly, but loan holds it as collateral)
        assertEq(ve.ownerOf(tokenId), address(loan), "NFT should be in loan custody");

        // Verify AERO was spent from buyer
        assertEq(IERC20(AERO).balanceOf(buyer), aeroBuyerBefore - userAeroAmount, "Buyer AERO should be spent");

        // Verify seller received payment
        assertTrue(IERC20(USDC).balanceOf(seller) > usdcSellerBefore, "Seller should receive USDC");

        console.log("Portfolio LBO test completed successfully!");
    }

    /**
     * @notice Test edge case: portfolio owns veNFT with no debt (paid off or never borrowed)
     * @dev This tests that a portfolio can list and sell a veNFT that has no outstanding loan
     *      Note: Portfolio-held veNFTs use makeLoanListing (not makeWalletListing) even with no debt
     */
    function test_portfolioOwnsVeNFT_noDebt() public {
        uint256 tokenId = 65424;
        IVotingEscrow ve = IVotingEscrow(VE);
        seller = ve.ownerOf(tokenId);
        vm.assume(seller != address(0));

        // Create seller portfolio
        vm.prank(seller);
        address sellerPortfolio = portfolioFactory.createAccount(seller);
        console.log("Seller portfolio created:", sellerPortfolio);

        // Transfer veNFT directly to portfolio (no loan involved)
        vm.prank(seller);
        ve.transferFrom(seller, sellerPortfolio, tokenId);

        // Verify portfolio owns the veNFT
        assertEq(ve.ownerOf(tokenId), sellerPortfolio, "Portfolio should own veNFT");

        // Verify no loan exists for this token
        (uint256 loanBalance, address borrower) = ILoanReq(address(loan)).getLoanDetails(tokenId);
        assertEq(loanBalance, 0, "Should have no loan balance");
        assertEq(borrower, address(0), "Should have no borrower");

        // Now seller can list the veNFT for sale using makeLoanListing (for portfolio-held NFTs)
        uint256 listingPrice = 30_000e6; // $30,000 USDC
        
        vm.prank(seller);
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, listingPrice, USDC, 0, address(0));

        // Verify listing was created with portfolio as owner
        (address listingOwner, uint256 price, address paymentToken, bool hasOutstandingLoan, ) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(listingOwner, sellerPortfolio, "Listing owner should be portfolio");
        assertEq(price, listingPrice, "Listing price should match");
        assertEq(paymentToken, USDC, "Payment token should be USDC");
        assertFalse(hasOutstandingLoan, "Should have no outstanding loan");

        // Buyer purchases the NFT using takeLoanListing
        buyer = vm.addr(0x5678);
        IUSDC_PL(USDC).mint(buyer, listingPrice);

        vm.startPrank(buyer);
        IERC20(USDC).approve(diamond, listingPrice);
        IMarketListingsLoanFacet(diamond).takeLoanListing(tokenId, USDC, 0, bytes(""), bytes(""));
        vm.stopPrank();

        // Verify buyer now owns the veNFT
        assertEq(ve.ownerOf(tokenId), buyer, "Buyer should now own veNFT");

        // Verify no loan was created in the process
        (loanBalance, borrower) = ILoanReq(address(loan)).getLoanDetails(tokenId);
        assertEq(loanBalance, 0, "Should still have no loan balance");
        assertEq(borrower, address(0), "Should still have no borrower");

        console.log("=== Portfolio No-Debt Edge Case ===");
        console.log("- veNFT transferred to portfolio without loan");
        console.log("- Listed via makeLoanListing (portfolio route)");
        console.log("- Sold successfully with no debt");
        console.log("Edge case test passed!");
    }

    /**
     * @notice Test: portfolio pays off loan, veNFT stays in loan custody (by design)
     * @dev Tests: LBO -> pay off -> verify veNFT remains in loan for rewards
     *      NOTE: veNFTs intentionally stay in loan custody after payoff to continue earning rewards
     */
    function test_portfolioLBO_payOff_veNFTStaysInLoan() public {
        uint256 tokenId = 65424;
        IVotingEscrow ve = IVotingEscrow(VE);
        seller = ve.ownerOf(tokenId);
        vm.assume(seller != address(0));

        // --- Phase 1: Execute LBO (same as main test) ---
        vm.startPrank(seller);
        uint256 listingPrice = 35_000e6;
        ve.approve(diamond, tokenId);
        IMarketListingsWalletFacet(diamond).makeWalletListing(tokenId, listingPrice, USDC, 0, address(0));
        vm.stopPrank();

        buyer = vm.addr(0x1234);
        uint256 userAeroAmount = 22000e18;
        deal(AERO, buyer, userAeroAmount);

        _createBuyerPortfolio();

        (uint256 maxLoanPossible,) = ILoan(address(loan)).getMaxLoan(tokenId);
        uint256 upfrontProtocolFee = (listingPrice * IMarketViewFacet(diamond).getLBOProtocolFeeBps()) / 10000;
        uint256 totalNeeded = listingPrice + upfrontProtocolFee;

        bytes memory lboTradeData = abi.encodeWithSelector(
            MockOdosRouterPL.executeMultiInputSwap.selector,
            AERO,
            userAeroAmount,
            maxLoanPossible,
            totalNeeded
        );

        vm.startPrank(buyer);
        IERC20(AERO).approve(buyerPortfolio, userAeroAmount);
        IPortfolioMarketplaceFacet(buyerPortfolio).executeLBO(
            tokenId,
            RouteLib.BuyRoute.InternalWallet,
            bytes32(0),
            USDC,
            listingPrice,
            AERO,
            userAeroAmount,
            bytes(""),
            lboTradeData,
            bytes("")
        );
        vm.stopPrank();

        // Verify loan exists with portfolio as borrower
        (uint256 loanBalance, address borrower) = ILoanReq(address(loan)).getLoanDetails(tokenId);
        assertEq(borrower, buyerPortfolio, "Portfolio should be borrower");
        assertTrue(loanBalance > 0, "Should have loan balance");
        console.log("Post-LBO loan balance:", loanBalance);

        // --- Phase 2: Pay off the loan ---
        uint256 payoffAmount = loanBalance + 1000e6; // Extra buffer
        IUSDC_PL(USDC).mint(buyerPortfolio, payoffAmount);

        vm.startPrank(buyerPortfolio);
        IERC20(USDC).approve(address(loan), payoffAmount);
        ILoan(address(loan)).pay(tokenId, loanBalance);
        vm.stopPrank();

        // Verify loan is paid off
        (loanBalance, borrower) = ILoanReq(address(loan)).getLoanDetails(tokenId);
        assertEq(loanBalance, 0, "Loan balance should be 0 after payoff");
        assertEq(borrower, buyerPortfolio, "Portfolio should still be borrower");
        
        // veNFT stays in loan custody by design (continues earning rewards)
        assertEq(ve.ownerOf(tokenId), address(loan), "veNFT should stay in loan custody after payoff");

        console.log("=== Post-Payoff Status ===");
        console.log("- Loan balance: 0");
        console.log("- Borrower (still): ", borrower);
        console.log("- veNFT owner (loan):", ve.ownerOf(tokenId));
        console.log("LBO payoff test passed - veNFT stays in loan for rewards!");
    }
}

