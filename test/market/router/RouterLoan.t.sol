// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DiamondMarketTestBase} from "../../utils/DiamondMarketTestBase.t.sol";
import {IMarketRouterFacet} from "src/interfaces/IMarketRouterFacet.sol";
import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {IMarketListingsLoanFacet} from "src/interfaces/IMarketListingsLoanFacet.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {RouteLib} from "src/libraries/RouteLib.sol";
import {BaseDeploy} from "script/BaseDeploy.s.sol";
import {Loan} from "src/LoanV2.sol";
import {Vault} from "src/VaultV2.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

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
    function setup(address _testContract) external { testContract = _testContract; }
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
}

contract RouterLoanTest is DiamondMarketTestBase {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant ODOS = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;
    address constant VE = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address constant LOAN_CANONICAL = 0x87f18b377e625b62c708D5f6EA96EC193558EFD0;
    Loan public loan;
    Vault public vault;

    address seller;
    address feeRecipient;

    function setUp() public {
        uint256 fork = vm.createFork("https://mainnet.base.org");
        vm.selectFork(fork);
        vm.rollFork(34683000);

        _deployDiamondAndFacets();

        feeRecipient = IOwnableMinimal_LR(LOAN_CANONICAL).owner();
        upgradeCanonicalLoan();
        _initMarket(LOAN_CANONICAL, VE, 250, feeRecipient, USDC);
        loan = Loan(LOAN_CANONICAL);
        
        IMarketConfigFacet(diamond).setAllowedPaymentToken(USDC, true);
        IMarketConfigFacet(diamond).setAllowedPaymentToken(AERO, true);

        // USDC minting for tests and mock Odos setup at canonical address
        vm.prank(IUSDC_LR(USDC).masterMinter());
        IUSDC_LR(USDC).configureMinter(address(this), type(uint256).max);
        MockOdosRouterRL mock = new MockOdosRouterRL();
        bytes memory code = address(mock).code;
        vm.etch(ODOS, code);
        MockOdosRouterRL(ODOS).setup(address(this));
    }

    // helper for mock to mint USDC to a recipient
    function mintUsdc(address /*minter*/, address to, uint256 amount) external {
        IUSDC_Mint(USDC).mint(to, amount);
    }

    function test_success_quoteToken_basic() public {
        // choose a token and move it to loan custody
        uint256 tokenId = 65424;
        IVotingEscrow ve = IVotingEscrow(VE);
        seller = ve.ownerOf(tokenId);
        vm.assume(seller != address(0));

        // transfer to loan custody
        vm.startPrank(seller);
        ve.approve(address(loan), tokenId);
        // zeroBalOption = 0 (DoNothing), other params zeroed/off
        loan.requestLoan(tokenId, 0, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();

        // sanity: ensure in custody (ownerOf != seller) and borrower recorded as seller
        ( , address borrower) = ILoanReq(address(loan)).getLoanDetails(tokenId);
        assertEq(borrower, seller);
        assertTrue(ve.ownerOf(tokenId) != seller);

        // create a loan listing payable in USDC
        vm.startPrank(seller);
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, 1_000e6, USDC, 0);
        vm.stopPrank();

        // quote via router
        (uint256 total, uint256 fee, address payToken) = IMarketRouterFacet(diamond).quoteToken(
            RouteLib.BuyRoute.InternalLoan,
            bytes32(0),
            tokenId,
            bytes("")
        );

        // total should equal price + loan balance; fee on listing price only
        // loan balance may be zero for this requestLoan path
        // At minimum, we check currency and fee computation
        assertEq(payToken, USDC);
        assertEq(fee, (1_000e6 * 250) / 10_000);
        assertTrue(total >= 1_000e6);
    }
}

contract RouterLoanBuyTest is RouterLoanTest {
    function test_success_buyToken_USDCInput_USDCPayment_withLoanPayoff_NoSwap() public {
        uint256 tokenId = 65424;
        IVotingEscrow ve = IVotingEscrow(VE);
        seller = ve.ownerOf(tokenId);
        vm.assume(seller != address(0));

        // Move token into loan custody with non-zero loan balance
        vm.startPrank(seller);
        ve.approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 500e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();

        // Create listing payable in USDC
        vm.startPrank(seller);
        uint256 price = 1_000e6;
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, price, USDC, 0);
        vm.stopPrank();

        // Determine current loan balance
        (uint256 loanBal, ) = ILoanReq(address(loan)).getLoanDetails(tokenId);

        // Fund buyer with USDC to cover listing + payoff (no swap path)
        address buyer = vm.addr(0xABCD);
        IUSDC_Mint(USDC).mint(buyer, price + loanBal);

        // Record balances for assertions
        uint256 usdcSellerBefore = IERC20(USDC).balanceOf(seller);
        uint256 usdcFeeBefore = IERC20(USDC).balanceOf(feeRecipient);

        // Approve and buy without tradeData (direct-token path)
        vm.startPrank(buyer);
        IERC20(USDC).approve(diamond, price + loanBal);
        IMarketRouterFacet(diamond).buyToken(
            RouteLib.BuyRoute.InternalLoan,
            bytes32(0),
            tokenId,
            USDC,
            price + loanBal,
            0,
            bytes(""),
            bytes(""),
            bytes("")
        );
        vm.stopPrank();

        // Borrower set to buyer and loan fully repaid
        (uint256 loanBalAfter, address borrower) = ILoanReq(address(loan)).getLoanDetails(tokenId);
        assertEq(borrower, buyer);
        assertEq(loanBalAfter, 0);

        // Seller receives price - router fee; fee recipient receives at least router fee (loan payoff may also route fees there)
        uint256 sellerDelta = IERC20(USDC).balanceOf(seller) - usdcSellerBefore;
        uint256 feeDelta = IERC20(USDC).balanceOf(feeRecipient) - usdcFeeBefore;
        uint256 routerFee = (price * 250) / 10_000;
        assertEq(sellerDelta, price - routerFee);
        assertTrue(feeDelta >= routerFee);
    }
    function test_success_buyToken_AEROInput_USDCPayment() public {
        uint256 tokenId = 65424;
        IVotingEscrow ve = IVotingEscrow(VE);
        seller = ve.ownerOf(tokenId);
        vm.assume(seller != address(0));

        // Move token into loan custody
        vm.startPrank(seller);
        ve.approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 0, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();

        // Create listing in USDC
        vm.startPrank(seller);
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, 1_000e6, USDC, 0);
        vm.stopPrank();

        // Quote
        (uint256 price, uint256 fee, address payToken) = IMarketRouterFacet(diamond).quoteToken(
            RouteLib.BuyRoute.InternalLoan,
            bytes32(0),
            tokenId,
            bytes("")
        );
        assertEq(payToken, USDC);

        address buyer = vm.addr(0x456);
        uint256 amountIn = 100e18; // AERO max input
        deal(AERO, buyer, amountIn);

        // record balances
        uint256 aeroBefore = IERC20(AERO).balanceOf(buyer);
        uint256 usdcSellerBefore = IERC20(USDC).balanceOf(seller);
        uint256 usdcFeeBefore = IERC20(USDC).balanceOf(feeRecipient);

        // Build tradeData for mock Odos
        bytes memory tradeData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            AERO,
            USDC,
            amountIn,
            price
        );

        // approve and buy
        vm.startPrank(buyer);
        IERC20(AERO).approve(diamond, amountIn);
        IMarketRouterFacet(diamond).buyToken(
            RouteLib.BuyRoute.InternalLoan,
            bytes32(0),
            tokenId,
            AERO,
            price + fee,
            amountIn,
            tradeData,
            bytes("") /* marketData */, 
            bytes("")
        );
        vm.stopPrank();

        // borrower set
        (, address borrower) = ILoanReq(address(loan)).getLoanDetails(tokenId);
        assertEq(borrower, buyer);

        // balances reflect transfer
        assertEq(IERC20(USDC).balanceOf(seller), usdcSellerBefore + price - fee);
        assertEq(IERC20(USDC).balanceOf(feeRecipient), usdcFeeBefore + fee);
        assertEq(aeroBefore - IERC20(AERO).balanceOf(buyer), amountIn);
    }

    function test_success_buyToken_ETHInput_USDCPayment() public {
        uint256 tokenId = 65424;
        IVotingEscrow ve = IVotingEscrow(VE);
        seller = ve.ownerOf(tokenId);
        vm.assume(seller != address(0));

        // Move token into loan custody
        vm.startPrank(seller);
        ve.approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 0, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();

        // Create listing in USDC
        vm.startPrank(seller);
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, 1_000e6, USDC, 0);
        vm.stopPrank();

        // Quote
        (uint256 price, uint256 fee, address payToken) = IMarketRouterFacet(diamond).quoteToken(
            RouteLib.BuyRoute.InternalLoan,
            bytes32(0),
            tokenId,
            bytes("")
        );
        assertEq(payToken, USDC);

        address buyer = vm.addr(0x4567);

        // Build tradeData for mock Odos: ETH -> USDC
        uint256 ethIn = 0.2 ether;
        bytes memory tradeData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwapETH.selector,
            USDC,
            price + fee
        );

        // balances before
        uint256 usdcSellerBefore = IERC20(USDC).balanceOf(seller);
        uint256 usdcFeeBefore = IERC20(USDC).balanceOf(feeRecipient);

        // buy with native ETH input (swap path)
        vm.deal(buyer, ethIn);
        vm.startPrank(buyer);
        IMarketRouterFacet(diamond).buyToken{value: ethIn}(
            RouteLib.BuyRoute.InternalLoan,
            bytes32(0),
            tokenId,
            address(0),
            price + fee,
            0,
            tradeData,
            bytes("") /* marketData */, 
            bytes("")
        );
        vm.stopPrank();

        // borrower set
        (, address borrower) = ILoanReq(address(loan)).getLoanDetails(tokenId);
        assertEq(borrower, buyer);

        // proceeds moved
        assertEq(IERC20(USDC).balanceOf(seller), usdcSellerBefore + price - fee);
        assertEq(IERC20(USDC).balanceOf(feeRecipient), usdcFeeBefore + fee);
    }

    function test_success_buyToken_ETHInput_AEROPayment_USDCPayoff_MultiOutputSwap() public {
        uint256 tokenId = 65424;
        IVotingEscrow ve = IVotingEscrow(VE);
        seller = ve.ownerOf(tokenId);
        vm.assume(seller != address(0));

        // Move token into loan custody with non-zero loan balance
        vm.startPrank(seller);
        ve.approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 400e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();

        // Create listing in AERO (different from loan asset USDC)
        vm.startPrank(seller);
        uint256 priceAero = 50e18;
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, priceAero, AERO, 0);
        vm.stopPrank();

        // Current loan balance (USDC)
        (uint256 loanBal, ) = ILoanReq(address(loan)).getLoanDetails(tokenId);

        // Replace ODOS with a multi-output mock that sends AERO and mints USDC
        MockOdosRouterRL_Multi multi = new MockOdosRouterRL_Multi();
        multi.setup(address(this));
        bytes memory multiCode = address(multi).code;
        vm.etch(ODOS, multiCode);

        // Fund ODOS with AERO to transfer out
        deal(AERO, ODOS, priceAero);

        // Prepare buyer and tradeData to receive both AERO and USDC
        address buyer = vm.addr(0xDEAD);
        vm.deal(buyer, 1 ether);
        bytes memory tradeData = abi.encodeWithSelector(
            MockOdosRouterRL_Multi.executeSwapETHMulti.selector,
            AERO,
            priceAero,
            USDC,
            loanBal
        );

        // Record balances
        uint256 aeroSellerBefore = IERC20(AERO).balanceOf(seller);
        uint256 aeroFeeBefore = IERC20(AERO).balanceOf(feeRecipient);

        // Buy via router with native ETH, multi-output swap
        vm.startPrank(buyer);
        IMarketRouterFacet(diamond).buyToken{value: 0.2 ether}(
            RouteLib.BuyRoute.InternalLoan,
            bytes32(0),
            tokenId,
            address(0),
            priceAero,
            0,
            tradeData,
            bytes(""),
            bytes("")
        );
        vm.stopPrank();

        // Loan fully repaid and borrower set
        (uint256 loanAfter, address borrower) = ILoanReq(address(loan)).getLoanDetails(tokenId);
        assertEq(borrower, buyer);
        assertEq(loanAfter, 0);

        // AERO proceeds distributed (fee + seller)
        uint256 fee = (priceAero * 250) / 10_000;
        assertEq(IERC20(AERO).balanceOf(seller), aeroSellerBefore + priceAero - fee);
        assertEq(IERC20(AERO).balanceOf(feeRecipient), aeroFeeBefore + fee);
    }
}

// Multi-output ODOS mock: transfers tokenOut1 (e.g., AERO) from itself and mints tokenOut2 USDC to msg.sender
contract MockOdosRouterRL_Multi {
    address public testContract;
    function setup(address _testContract) external { testContract = _testContract; }
    function executeSwapETHMulti(address tokenOut1, uint256 amountOut1, address tokenOut2, uint256 amountOut2) external payable returns (bool) {
        require(msg.value > 0, "no eth");
        IERC20(tokenOut1).transfer(msg.sender, amountOut1);
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", IUSDC_Mint(tokenOut2).masterMinter(), msg.sender, amountOut2));
        require(success, "mint fail");
        return true;
    }
}
