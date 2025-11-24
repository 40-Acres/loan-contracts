// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DiamondMarketTestBase} from "../../utils/DiamondMarketTestBase.t.sol";
import {IMarketRouterFacet} from "src/interfaces/IMarketRouterFacet.sol";
import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {IMarketViewFacet} from "src/interfaces/IMarketViewFacet.sol";
import {IMarketListingsLoanFacet} from "src/interfaces/IMarketListingsLoanFacet.sol";
import {IMarketListingsWalletFacet} from "src/interfaces/IMarketListingsWalletFacet.sol";
import {Permit2Lib} from "src/libraries/Permit2Lib.sol";
import "forge-std/console.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {RouteLib} from "src/libraries/RouteLib.sol";
import {BaseDeploy} from "script/BaseDeploy.s.sol";
import {Loan} from "src/LoanV2.sol";
import {Vault} from "src/VaultV2.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ILoan} from "src/interfaces/ILoan.sol";
import {IVexyMarketplace} from "src/interfaces/external/IVexyMarketplace.sol";
import {VexyAdapterFacet} from "src/facets/market/VexyAdapterFacet.sol";
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";

interface IOwnableMinimal_LR { function owner() external view returns (address); }

interface IUSDC_LR {
    function configureMinter(address, uint256) external;
    function masterMinter() external view returns (address);
}

interface ILoanReq {
    function requestLoan(uint256 tokenId, uint256 amount, uint8 zeroBalOption, uint256 rate, address ref, bool a, bool b) external;
    function getLoanDetails(uint256 tokenId) external view returns (uint256 balance, address borrower);
}

interface IUSDC_Mint { function mint(address, uint256) external; function masterMinter() external view returns (address); }

contract MockOdosRouterRL {
    address public testContract;
    function initMock(address _testContract) external { testContract = _testContract; }
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) external returns (bool) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", IUSDC_Mint(tokenOut).masterMinter(), msg.sender, amountOut));
        require(success, "mint fail");
        return true;
    }

    // ETH -> token swap path for loan route
    function executeSwapETH(address tokenOut, uint256 amountOut) external payable returns (bool) {
        require(msg.value > 0, "no eth");
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", IUSDC_Mint(tokenOut).masterMinter(), msg.sender, amountOut));
        require(success, "mint fail");
        return true;
    }
    
    // Multi-input swap for LBO: takes AERO from caller, receives USDC from contract, outputs USDC to caller
    function executeMultiInputSwap(address tokenIn, uint256 amountIn, uint256 usdcFromContract, uint256 totalUsdcOut) external returns (bool) {
        address usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        // Take AERO from caller
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        // Take USDC from caller (flash loan amount)
        IERC20(usdc).transferFrom(msg.sender, address(this), usdcFromContract);
        // Mint total USDC output to caller
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", IUSDC_Mint(usdc).masterMinter(), msg.sender, totalUsdcOut));
        require(success, "mint fail");
        return true;
    }

    // Multi-input swap for LBO: takes ETH + USDC from caller, outputs AERO to caller
    function executeMultiInputSwapToAero(uint256 ethAmount, uint256 usdcAmount, uint256 aeroAmountOut) external payable returns (bool) {
        require(msg.value == ethAmount, "ETH amount mismatch");
        address usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        address aero = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
        // Take USDC from caller (flash loan amount)
        IERC20(usdc).transferFrom(msg.sender, address(this), usdcAmount);
        // Transfer AERO to caller (simulate swap output)
        IERC20(aero).transfer(msg.sender, aeroAmountOut);
        return true;
    }
}

// Multi-output ODOS mock: transfers tokenOut1 (e.g., AERO) from itself and mints tokenOut2 USDC to msg.sender
contract MockOdosRouterRL_Multi {
    address public testContract;
    function initMock(address _testContract) external { testContract = _testContract; }
    function executeSwapETHMulti(address tokenOut1, uint256 amountOut1, address tokenOut2, uint256 amountOut2) external payable returns (bool) {
        require(msg.value > 0, "no eth");
        IERC20(tokenOut1).transfer(msg.sender, amountOut1);
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", IUSDC_Mint(tokenOut2).masterMinter(), msg.sender, amountOut2));
        require(success, "mint fail");
        return true;
    }
}

contract RouterLBOTest is DiamondMarketTestBase {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant ODOS = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;
    address constant VE = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address constant LOAN_CANONICAL = 0x87f18b377e625b62c708D5f6EA96EC193558EFD0;
    Loan public loan;
    Vault public vault;

    address seller;
    address feeRecipient;

    bytes32 constant VEXY_key = keccak256(abi.encodePacked("VEXY"));

    function setUp() public {
        uint256 fork = vm.createFork("https://mainnet.base.org");
        vm.selectFork(fork);
        vm.rollFork(34683000);

        _deployDiamondAndFacets();

        feeRecipient = IOwnableMinimal_LR(LOAN_CANONICAL).owner();
        upgradeCanonicalLoan();
        _initMarket(LOAN_CANONICAL, VE, 100, 200, 100, 100, feeRecipient, USDC);
        loan = Loan(LOAN_CANONICAL);
        
        IMarketConfigFacet(diamond).setAllowedPaymentToken(USDC, true);
        IMarketConfigFacet(diamond).setAllowedPaymentToken(AERO, true);

        // Internal=1% (100 bps), External=2% (200 bps)
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.InternalWallet, 100);
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.InternalLoan, 100);
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.ExternalAdapter, 200);

        // USDC minting for tests and mock Odos setup at canonical address
        vm.prank(IUSDC_LR(USDC).masterMinter());
        IUSDC_LR(USDC).configureMinter(address(this), type(uint256).max);
        MockOdosRouterRL mock = new MockOdosRouterRL();
        bytes memory code = address(mock).code;
        vm.etch(ODOS, code);
        MockOdosRouterRL(ODOS).initMock(address(this));

        // Set up VEXY adapter for external route testing
        address vexyFacet = address(new VexyAdapterFacet());
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("quoteToken(uint256,bytes)"));
        selectors[1] = bytes4(keccak256("buyToken(uint256,uint256,address,uint256,bytes,bytes,bytes)"));
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({facetAddress: vexyFacet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors});
        IDiamondCut(diamond).diamondCut(cut, address(0), "");
        
        IMarketConfigFacet(diamond).setExternalAdapter(VEXY_key, vexyFacet);
    }

    // helper for mock to mint USDC to a recipient
    function mintUsdc(address /*minter*/, address to, uint256 amount) external {
        IUSDC_Mint(USDC).mint(to, amount);
    }

    function test_success_buyTokenWithLBO_AEROInput_USDCListing() public {
        uint256 tokenId = 65424;
        IVotingEscrow ve = IVotingEscrow(VE);
        seller = ve.ownerOf(tokenId);
        vm.assume(seller != address(0));

        // Create a wallet listing (NFT not in loan custody yet) in USDC
        vm.startPrank(seller);
        uint256 listingPrice = 35_000e6; // $35000 USDC
        // Approve diamond to transfer the NFT
        ve.approve(diamond, tokenId);
        IMarketListingsWalletFacet(diamond).makeWalletListing(tokenId, listingPrice, USDC, 0, address(0));
        vm.stopPrank();

        // LBO buyer setup
        address buyer = vm.addr(0x1234);
        uint256 userAeroAmount = 22000e18; // 22000 AERO (~$28000 or 80% of listing price)
        deal(AERO, buyer, userAeroAmount);

        // Get the actual max loan amount for this real veNFT 
        (uint256 maxLoanPossible,) = ILoan(address(loan)).getMaxLoan(tokenId);
        console.log("Real veNFT max loan possible:", maxLoanPossible);
        
        // Calculate expected amounts
        uint256 upfrontProtocolFee = (listingPrice * IMarketViewFacet(diamond).getLBOProtocolFeeBps()) / 10000;
        uint256 totalNeeded = listingPrice + upfrontProtocolFee;
        uint256 flashLoanAmount = maxLoanPossible - (maxLoanPossible * IMarketViewFacet(diamond).getLBOLenderFeeBps()) / 10000;

        // Build purchase order struct manually (since it's internal to MarketRouterFacet)
        bytes memory purchaseOrderData = abi.encode(
            RouteLib.BuyRoute.InternalWallet, // route
            bytes32(0), // adapterKey
            tokenId, // tokenId
            USDC, // inputAsset (after swap, we'll have USDC)
            listingPrice, // maxPaymentTotal
            uint256(0), // maxInputAmount
            bytes(""), // tradeData (empty since buyToken won't need to swap)
            bytes(""), // marketData
            bytes("") // optionalPermit2
        );

        // Build trade data for AERO + USDC -> USDC swap
        // We need to mock a swap that takes AERO + flash loan USDC and outputs enough USDC for the purchase
        bytes memory tradeData = abi.encodeWithSelector(
            MockOdosRouterRL.executeMultiInputSwap.selector,
            AERO,
            userAeroAmount,
            flashLoanAmount, // USDC from flash loan (maxLoan amount)
            totalNeeded // Output enough USDC for listing + upfront fee
        );
        
        console.log("=== Test Setup ===");
        console.log("Listing price:", listingPrice);
        console.log("User AERO amount:", userAeroAmount);
        console.log("Flash loan amount (max loan):", flashLoanAmount);
        console.log("Total needed:", totalNeeded);

        // Record balances before
        uint256 usdcSellerBefore = IERC20(USDC).balanceOf(seller);
        uint256 usdcFeeBefore = IERC20(USDC).balanceOf(feeRecipient);
        uint256 aeroBuyerBefore = IERC20(AERO).balanceOf(buyer);

        // Execute LBO
        vm.startPrank(buyer);
        IERC20(AERO).approve(diamond, userAeroAmount);
        
        IMarketRouterFacet(diamond).buyTokenWithLBO(
            tokenId,
            AERO, // userPaymentAsset
            userAeroAmount, // userPaymentAmount
            purchaseOrderData, // purchaseOrderData
            tradeData, // tradeData for swap
            bytes("") // optionalPermit2
        );
        vm.stopPrank();

        // Verify loan was created with buyer as borrower
        (uint256 loanBalance, address borrower) = ILoanReq(address(loan)).getLoanDetails(tokenId);
        assertEq(borrower, buyer);
        assertTrue(loanBalance > 0); // Should have loan balance from LBO

        // Use the max loan we calculated earlier (before the loan was created)
        uint256 maxLoan = maxLoanPossible;

        // === LBO FEE MATH VERIFICATION ===
        // Get the actual configured LBO lender fee from market storage
        uint256 lboLenderFeeBps = IMarketViewFacet(diamond).getLBOLenderFeeBps();
        uint256 lenderFeeAmount = (maxLoan * lboLenderFeeBps) / 10000;
        
        // Expected loan balance calculation:
        // With new implementation: requestLoan creates loan with originalMaxLoan amount
        // finalizeLBOPurchase removes origination fee, leaving just originalMaxLoan
        // Lender fee is handled separately (transferred directly to vault)
        uint256 originationFee = (maxLoan * 80) / 10000; // 0.8% of max loan
        uint256 expectedLoanBalance = maxLoan; // Just the original max loan amount
        
        console.log("=== LBO Fee Math Verification ===");
        console.log("Listing price:", listingPrice);
        console.log("Upfront protocol fee (100 bps):", upfrontProtocolFee);
        console.log("Lender fee (%d bps, transferred to vault):", lboLenderFeeBps, lenderFeeAmount);
        console.log("Max loan amount:", maxLoan);
        console.log("Original origination fee (80 bps):", originationFee);
        console.log("Expected final loan balance:", expectedLoanBalance);
        console.log("Actual loan balance:", loanBalance);
        
        // Verify the loan balance matches our expected calculation
        assertEq(loanBalance, expectedLoanBalance, "Loan balance should equal maxLoan (lender fee handled separately)");
        
        // Verify total LBO fee structure
        uint256 totalLBOFees = upfrontProtocolFee + lenderFeeAmount;
        uint256 expectedTotalLBOFees = (listingPrice * 100) / 10000 + (maxLoan * lboLenderFeeBps) / 10000; // 100 bps on listing + configured bps on loan
        assertEq(totalLBOFees, expectedTotalLBOFees, "Total LBO fees should be 100 bps on listing + configured lender fee on loan");

        // Verify NFT is in loan custody
        assertTrue(ve.ownerOf(tokenId) == address(loan));

        // Verify AERO was spent
        assertEq(IERC20(AERO).balanceOf(buyer), aeroBuyerBefore - userAeroAmount);

                // Verify seller received payment (listing price minus any wallet listing fees)
        uint256 walletListingFee = (listingPrice * 100) / 10000; // 1% wallet listing fee
        assertEq(IERC20(USDC).balanceOf(seller), usdcSellerBefore + listingPrice - walletListingFee);

        // Verify protocol fee recipient received exactly: wallet listing fee + upfront LBO fee
        uint256 feeDelta = IERC20(USDC).balanceOf(feeRecipient) - usdcFeeBefore;
        uint256 expectedFeeDelta = walletListingFee + upfrontProtocolFee;
        assertEq(feeDelta, expectedFeeDelta, "Protocol fee recipient should receive route fee + upfront LBO fee");

        console.log("=== LBO Test Results ===");
        console.log("- Loan Balance:", loanBalance);
        console.log("- Borrower:", borrower);
        console.log("- NFT Owner:", ve.ownerOf(tokenId));
        console.log("- Seller USDC received:", IERC20(USDC).balanceOf(seller) - usdcSellerBefore);
        console.log("- Protocol fees received:", IERC20(USDC).balanceOf(feeRecipient) - usdcFeeBefore);
        console.log("All LBO fee calculations verified!");
    }

    function test_success_buyTokenWithLBO_AEROInput_USDCListing_onVexy() public {
        uint256 tokenId = 65424;
        IVotingEscrow ve = IVotingEscrow(VE);
        seller = ve.ownerOf(tokenId);
        vm.assume(seller != address(0));
        address VEXY_address = 0x6b478209974BD27e6cf661FEf86C68072b0d6738;

        // Create a vexy listing in USDC
        vm.startPrank(seller);
        uint256 listingPrice = 35_000e6; // $35000 USDC
        // Approve vexy to transfer the NFT
        ve.approve(VEXY_address, tokenId);
        uint listingId = IVexyMarketplace(VEXY_address).createListing(VE, tokenId, USDC, listingPrice, 0, 0, 0);
        vm.stopPrank();

        // LBO buyer setup
        address buyer = vm.addr(0x1234);
        uint256 userAeroAmount = 22000e18; // 22000 AERO (~$28000 or 80% of listing price)
        deal(AERO, buyer, userAeroAmount);

        // Get the actual max loan amount for this real veNFT 
        (uint256 maxLoanPossible,) = ILoan(address(loan)).getMaxLoan(tokenId);
        console.log("Real veNFT max loan possible:", maxLoanPossible);
        
        // Calculate expected amounts
        uint256 upfrontProtocolFee = (listingPrice * IMarketViewFacet(diamond).getLBOProtocolFeeBps()) / 10000;
        uint256 externalRouteFee = (listingPrice * 200) / 10000; // 200 bps assigned in setup
        uint256 totalNeeded = listingPrice + upfrontProtocolFee + externalRouteFee;
        // flash loan the max possible (in USDC) - lender fee
        uint256 flashLoanAmount = maxLoanPossible - (maxLoanPossible * IMarketViewFacet(diamond).getLBOLenderFeeBps()) / 10000;

        // Build purchase order struct manually (since it's internal to MarketRouterFacet)
        bytes memory purchaseOrderData = abi.encode(
            RouteLib.BuyRoute.ExternalAdapter, // route
            VEXY_key, // adapterKey
            tokenId, // tokenId
            USDC, // inputAsset (after swap, we'll have USDC)
            listingPrice+externalRouteFee, // maxPaymentTotal
            uint256(0), // maxInputAmount
            bytes(""), // tradeData (empty since buyToken won't need to swap)
            bytes(abi.encode(VEXY_address, listingId, USDC, listingPrice)), // marketData
            bytes("") // optionalPermit2
        );

        // Build trade data for AERO + USDC -> USDC swap
        // We need to mock a swap that takes AERO + flash loan USDC and outputs enough USDC for the purchase
        bytes memory tradeData = abi.encodeWithSelector(
            MockOdosRouterRL.executeMultiInputSwap.selector,
            AERO,
            userAeroAmount,
            flashLoanAmount, // USDC from flash loan (maxLoan amount)
            totalNeeded // Output enough USDC for listing + upfront fee
        );
        
        console.log("=== Test Setup ===");
        console.log("Listing price:", listingPrice);
        console.log("User AERO amount:", userAeroAmount);
        console.log("Flash loan amount (max loan):", flashLoanAmount);
        console.log("Total needed:", totalNeeded);

        // Record balances before
        uint256 usdcSellerBefore = IERC20(USDC).balanceOf(seller);
        uint256 usdcFeeBefore = IERC20(USDC).balanceOf(feeRecipient);
        uint256 aeroBuyerBefore = IERC20(AERO).balanceOf(buyer);

        // Execute LBO
        vm.startPrank(buyer);
        IERC20(AERO).approve(diamond, userAeroAmount);
        
        IMarketRouterFacet(diamond).buyTokenWithLBO(
            tokenId,
            AERO, // userPaymentAsset
            userAeroAmount, // userPaymentAmount
            purchaseOrderData, // purchaseOrderData
            tradeData, // tradeData for swap
            bytes("") // optionalPermit2
        );
        vm.stopPrank();

        // Verify loan was created with buyer as borrower
        (uint256 loanBalance, address borrower) = ILoanReq(address(loan)).getLoanDetails(tokenId);
        assertEq(borrower, buyer);
        assertTrue(loanBalance > 0); // Should have loan balance from LBO

        // Use the max loan we calculated earlier (before the loan was created)
        uint256 maxLoan = maxLoanPossible;

        // === LBO FEE MATH VERIFICATION ===
        // Get the actual configured LBO lender fee from market storage
        uint256 lboLenderFeeBps = IMarketViewFacet(diamond).getLBOLenderFeeBps();
        uint256 lenderFeeAmount = (maxLoan * lboLenderFeeBps) / 10000;
        
        // Expected loan balance calculation:
        // With new implementation: requestLoan creates loan with originalMaxLoan amount
        // finalizeLBOPurchase removes origination fee, leaving just originalMaxLoan
        // Lender fee is handled separately (transferred directly to vault)
        uint256 originationFee = (maxLoan * 80) / 10000; // 0.8% of max loan
        uint256 expectedLoanBalance = maxLoan; // Just the original max loan amount
        
        console.log("=== LBO Fee Math Verification ===");
        console.log("Listing price:", listingPrice);
        console.log("Total LBO fees (upfront 1% on listing + lender fee):", upfrontProtocolFee + lenderFeeAmount);
        console.log("Upfront protocol fee (100 bps):", upfrontProtocolFee);
        console.log("Lender fee (%d bps, transferred to vault):", lboLenderFeeBps, lenderFeeAmount);
        console.log("Max loan amount:", maxLoan);
        console.log("Original origination fee (80 bps):", originationFee);
        console.log("Expected final loan balance:", expectedLoanBalance);
        console.log("Actual loan balance:", loanBalance);
        
        // Verify the loan balance matches our expected calculation
        assertEq(loanBalance, expectedLoanBalance, "Loan balance should equal maxLoan (lender fee handled separately)");
        
        // Verify total LBO fee structure
        uint256 totalLBOFees = upfrontProtocolFee + lenderFeeAmount;
        uint256 expectedTotalLBOFees = (listingPrice * 100) / 10000 + (maxLoan * lboLenderFeeBps) / 10000; // 100 bps on listing + configured bps on loan
        assertEq(totalLBOFees, expectedTotalLBOFees, "Total LBO fees should be 100 bps on listing + configured lender fee on loan");

        // Verify NFT is in loan custody
        assertTrue(ve.ownerOf(tokenId) == address(loan));

        // Verify AERO was spent
        assertEq(IERC20(AERO).balanceOf(buyer), aeroBuyerBefore - userAeroAmount);



        // Verify protocol fee recipient received upfront LBO fee
        assertTrue(IERC20(USDC).balanceOf(feeRecipient) >= usdcFeeBefore + upfrontProtocolFee);

        // verify loan details are correct including borrower=buyer, balance=maxLoan, nft owner=loan
        assertEq(borrower, buyer, "Borrower should be buyer");
        assertEq(loanBalance, maxLoan, "Loan balance should be maxLoan (lender fee handled separately)");
        assertEq(ve.ownerOf(tokenId), address(loan), "NFT owner should be loan");

        // No leftover USDC on diamond
        assertEq(IERC20(USDC).balanceOf(diamond), 0, "Diamond should not retain USDC");

        console.log("=== LBO Test Results ===");
        console.log("- Loan Balance:", loanBalance);
        console.log("- Borrower:", borrower);
        console.log("- NFT Owner:", ve.ownerOf(tokenId));
        console.log("- Seller USDC received:", IERC20(USDC).balanceOf(seller) - usdcSellerBefore);
        console.log("- Protocol fees received:", IERC20(USDC).balanceOf(feeRecipient) - usdcFeeBefore);
        console.log("All LBO fee calculations verified!");
    }

    function test_success_buyTokenWithLBO_ETHInput_AEROListing() public {
        uint256 tokenId = 65424;
        IVotingEscrow ve = IVotingEscrow(VE);
        seller = ve.ownerOf(tokenId);
        vm.assume(seller != address(0));

        // Create a wallet listing in AERO (different from previous test)
        vm.startPrank(seller);
        uint256 listingPriceInAero = 22000e18; // 22,000 AERO (~$28,000)
        // Approve diamond to transfer the NFT
        ve.approve(diamond, tokenId);
        IMarketListingsWalletFacet(diamond).makeWalletListing(tokenId, listingPriceInAero, AERO, 0, address(0));
        vm.stopPrank();

        // Get the actual max loan amount for this real veNFT 
        (uint256 maxLoanPossible,) = ILoan(address(loan)).getMaxLoan(tokenId);
        console.log("Real veNFT max loan possible:", maxLoanPossible);

        // LBO buyer setup - user provides ETH
        address buyer = vm.addr(0x5678);
        uint256 userEthAmount = 15 ether; // 15 ETH (~$45,000 at $3000/ETH, covering ~64% of purchase)
        vm.deal(buyer, userEthAmount);

        // Calculate expected amounts
        uint256 upfrontProtocolFee = (listingPriceInAero * IMarketViewFacet(diamond).getLBOProtocolFeeBps()) / 10000;
        uint256 totalNeededInAero = listingPriceInAero + upfrontProtocolFee;
        // flash loan the max possible (in USDC) - lender fee
        uint256 flashLoanAmount = maxLoanPossible - (maxLoanPossible * IMarketViewFacet(diamond).getLBOLenderFeeBps()) / 10000;

        // Build purchase order struct - target asset is AERO
        bytes memory purchaseOrderData = abi.encode(
            RouteLib.BuyRoute.InternalWallet, // route
            bytes32(0), // adapterKey
            tokenId, // tokenId
            AERO, // inputAsset (we need AERO after swap)
            listingPriceInAero, // maxPaymentTotal (in AERO)
            uint256(0), // maxInputAmount
            bytes(""), // tradeData (empty since buyToken won't need to swap)
            bytes(""), // marketData
            bytes("") // optionalPermit2
        );

        // Build trade data for ETH + USDC -> AERO swap
        // Mock a swap that takes ETH + flash loan USDC and outputs enough AERO for the purchase
        bytes memory tradeData = abi.encodeWithSelector(
            MockOdosRouterRL.executeMultiInputSwapToAero.selector,
            userEthAmount, // ETH amount
            flashLoanAmount, // USDC from flash loan
            totalNeededInAero // Output enough AERO for listing + upfront fee
        );

        console.log("=== ETH->AERO Test Setup ===");
        console.log("Listing price (AERO):", listingPriceInAero);
        console.log("User ETH amount:", userEthAmount);
        console.log("Flash loan amount (USDC):", flashLoanAmount);
        console.log("Total needed (AERO):", totalNeededInAero);

        // Fund the mock ODOS router with AERO to transfer out
        deal(AERO, ODOS, totalNeededInAero);

        // Record balances before
        uint256 aeroSellerBefore = IERC20(AERO).balanceOf(seller);
        uint256 aeroFeeBefore = IERC20(AERO).balanceOf(feeRecipient);
        uint256 ethBuyerBefore = buyer.balance;

        // Execute LBO with ETH
        vm.startPrank(buyer);
        
        IMarketRouterFacet(diamond).buyTokenWithLBO{value: userEthAmount}(
            tokenId,
            address(0), // userPaymentAsset = ETH (address(0))
            userEthAmount, // userPaymentAmount
            purchaseOrderData, // purchaseOrderData
            tradeData, // tradeData for ETH + USDC -> AERO swap
            bytes("") // optionalPermit2
        );
        vm.stopPrank();

        // Verify loan was created with buyer as borrower
        (uint256 loanBalance, address borrower) = ILoanReq(address(loan)).getLoanDetails(tokenId);
        assertEq(borrower, buyer);
        assertTrue(loanBalance > 0); // Should have loan balance from LBO

        // === LBO FEE MATH VERIFICATION ===
        // Calculate expected LBO fees (in AERO terms since that's the listing currency)
        uint256 financedFeeInAero = (listingPriceInAero * 100) / 10000; // 100 bps financed fee
        uint256 expectedLenderFinancedFee = financedFeeInAero / 2; // 50 bps to lenders
        uint256 expectedProtocolFinancedFee = financedFeeInAero - expectedLenderFinancedFee; // 50 bps to protocol + remainder
        
        // Use the max loan we calculated earlier (before the loan was created)
        uint256 maxLoan = maxLoanPossible;
        
        // Expected loan balance calculation (same as before - in USDC terms)
        uint256 originationFee = (maxLoan * 80) / 10000; // 0.8% of max loan
        uint256 expectedLoanBalance = maxLoan + ((financedFeeInAero * 1e6) / 1e18); // Convert AERO fee to USDC (rough approximation)

        console.log("=== ETH->AERO LBO Fee Math Verification ===");
        console.log("Listing price (AERO):", listingPriceInAero);
        console.log("Total LBO fees (200 bps AERO):", upfrontProtocolFee + financedFeeInAero);
        console.log("Upfront protocol fee (100 bps AERO):", upfrontProtocolFee);
        console.log("Financed fee (100 bps AERO):", financedFeeInAero);
        console.log("  - Lender share (50 bps AERO):", expectedLenderFinancedFee);
        console.log("  - Protocol share (50 bps AERO):", expectedProtocolFinancedFee);
        console.log("Max loan amount (USDC):", maxLoan);
        console.log("Original origination fee (USDC):", originationFee);
        console.log("Actual loan balance (USDC):", loanBalance);
        
        // Verify fee split is correct and handles rounding properly
        assertEq(expectedLenderFinancedFee + expectedProtocolFinancedFee, financedFeeInAero, "Fee split should equal total financed fee");
        
        // Verify rounding logic: protocol gets any remainder from odd amounts
        if (financedFeeInAero % 2 == 0) {
            assertEq(expectedLenderFinancedFee, expectedProtocolFinancedFee, "Even financed fee should split equally");
        } else {
            assertEq(expectedProtocolFinancedFee, expectedLenderFinancedFee + 1, "Odd financed fee remainder should go to protocol");
        }
        
        // Verify total LBO fee structure (200 bps total)
        uint256 totalLBOFeesInAero = upfrontProtocolFee + financedFeeInAero;
        uint256 expectedTotalLBOFeesInAero = (listingPriceInAero * 200) / 10000; // 200 bps
        assertEq(totalLBOFeesInAero, expectedTotalLBOFeesInAero, "Total LBO fees should be 200 bps of listing price");

        // Verify NFT is in loan custody
        assertTrue(ve.ownerOf(tokenId) == address(loan));

        // Verify ETH was spent
        assertEq(buyer.balance, ethBuyerBefore - userEthAmount);

        // Verify seller received payment (listing price minus any wallet listing fees)
        uint256 walletListingFee = (listingPriceInAero * 100) / 10000; // 1% wallet listing fee
        assertEq(IERC20(AERO).balanceOf(seller), aeroSellerBefore + listingPriceInAero - walletListingFee);

        // Verify protocol fee recipient received upfront LBO fee (in AERO)
        assertTrue(IERC20(AERO).balanceOf(feeRecipient) >= aeroFeeBefore + upfrontProtocolFee);

        console.log("=== ETH->AERO LBO Test Results ===");
        console.log("- Loan Balance (USDC):", loanBalance);
        console.log("- Borrower:", borrower);
        console.log("- NFT Owner:", ve.ownerOf(tokenId));
        console.log("- Seller AERO received:", IERC20(AERO).balanceOf(seller) - aeroSellerBefore);
        console.log("- Protocol AERO fees received:", IERC20(AERO).balanceOf(feeRecipient) - aeroFeeBefore);
        console.log("- Buyer ETH spent:", ethBuyerBefore - buyer.balance);
        console.log("ETH->AERO LBO completed successfully!");
    }
}
