// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DiamondMarketTestBase} from "../../utils/DiamondMarketTestBase.t.sol";
import {IMarketRouterFacet} from "src/interfaces/IMarketRouterFacet.sol";
import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {IMarketListingsWalletFacet} from "src/interfaces/IMarketListingsWalletFacet.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {RouteLib} from "src/libraries/RouteLib.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IOwnableMinimal { function owner() external view returns (address); }

interface IUSDC {
    function mint(address, uint256) external;
    function configureMinter(address, uint256) external;
    function masterMinter() external view returns (address);
}

contract MockOdosRouterRW {
    IERC20 public tokenInRef;
    IERC20 public tokenOutRef;
    address public testContract;

    function initMock(address _testContract) external {
        testContract = _testContract;
    }

    // Generic swap: pull tokenIn from msg.sender, mint tokenOut to msg.sender using test hook
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) external returns (bool) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", IUSDC(tokenOut).masterMinter(), msg.sender, amountOut));
        require(success, "mint fail");
        return true;
    }

    // ETH -> token swap path: accept ETH and mint tokenOut to msg.sender via test hook
    function executeSwapETH(address tokenOut, uint256 amountOut) external payable returns (bool) {
        require(msg.value > 0, "no eth");
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", IUSDC(tokenOut).masterMinter(), msg.sender, amountOut));
        require(success, "mint fail");
        return true;
    }
}

contract RouterWalletTest is DiamondMarketTestBase {
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant VE = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address constant LOAN = 0x87f18b377e625b62c708D5f6EA96EC193558EFD0;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address buyer;
    address seller;
    address feeRecipient;
    address constant ODOS = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;

    function setUp() public {
        uint256 fork = vm.createFork("https://mainnet.base.org");
        vm.selectFork(fork);
        vm.rollFork(34683000);

        _deployDiamondAndFacets();

        feeRecipient = IOwnableMinimal(LOAN).owner();
        // ensure canonical loan proxy is upgraded on fork before market init
        upgradeCanonicalLoan();
        _initMarket(BASE_LOAN_CANONICAL, VE, 100, 200, 100, 100, feeRecipient, USDC);

        // allow payment tokens (AERO, USDC, WETH)
        IMarketConfigFacet(diamond).setAllowedPaymentToken(USDC, true);
        IMarketConfigFacet(diamond).setAllowedPaymentToken(AERO, true);
        IMarketConfigFacet(diamond).setAllowedPaymentToken(WETH, true);

        // set permit2
        IMarketConfigFacet(diamond).setPermit2(PERMIT2);


        // prepare a real wallet listing for tokenId 65424 priced in USDC
        uint256 tokenId = 65424;
        IVotingEscrow ve = IVotingEscrow(VE);
        seller = ve.ownerOf(tokenId);
        vm.assume(seller != address(0));

        vm.startPrank(seller);
        ve.approve(diamond, tokenId);
        IMarketListingsWalletFacet(diamond).makeWalletListing(tokenId, 1_000e6, USDC, 0, address(0));
        vm.stopPrank();

        // seed buyer with ample WETH for swap input (we know WETH->USDC works)
        buyer = vm.addr(0x456);
        deal(WETH, buyer, 10e18); // 10 WETH

        router = IMarketRouterFacet(diamond);

        // Internal=1% (100 bps), External=2% (200 bps)
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.InternalWallet, 100);
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.InternalLoan, 100);
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.ExternalAdapter, 200);

        // Configure this test as USDC minter and etch mock Odos
        vm.prank(IUSDC(USDC).masterMinter());
        IUSDC(USDC).configureMinter(address(this), type(uint256).max);
        MockOdosRouterRW mock = new MockOdosRouterRW();
        mock.initMock(address(this));
        bytes memory code = address(mock).code;
        vm.etch(ODOS, code);
        MockOdosRouterRW(ODOS).initMock(address(this));
    }

    function test_success_quoteToken_basic() public {
        uint256 tokenId = 65424;
        (uint256 price, uint256 fee, address payToken) = router.quoteToken(
            RouteLib.BuyRoute.InternalWallet,
            bytes32(0),
            tokenId,
            bytes("")
        );
        // Basic sanity assertions
        assertEq(price, 1_000e6);
        assertEq(payToken, USDC);
        assertEq(fee, (price * 100) / 10_000);
    }

    function test_success_buyToken_WETHInput_USDCPayment() public {
        uint256 tokenId = 65424;
        (uint256 price, uint256 fee, address payToken) = router.quoteToken(
            RouteLib.BuyRoute.InternalWallet,
            bytes32(0),
            tokenId,
            bytes("")
        );
        assertEq(price, 1_000e6);
        assertEq(payToken, USDC);
        assertEq(fee, (price * 100) / 10_000);

        // record balances
        uint256 wethBuyerBefore = IERC20(WETH).balanceOf(buyer);
        uint256 usdcSellerBefore = IERC20(USDC).balanceOf(seller);
        uint256 usdcFeeBefore = IERC20(USDC).balanceOf(feeRecipient);

        // Build tradeData for mock Odos: swap WETH -> USDC, amountIn=1e17, amountOut=price
        uint256 amountIn = 1e17; // 0.1 WETH as max input
        bytes memory tradeData = abi.encodeWithSelector(
            MockOdosRouterRW.executeSwap.selector,
            WETH,
            USDC,
            amountIn,
            price
        );

        // approve and buy
        vm.startPrank(buyer);
        IERC20(WETH).approve(diamond, amountIn);
        router.buyToken(
            RouteLib.BuyRoute.InternalWallet,
            bytes32(0),
            tokenId,
            WETH,
            price,
            amountIn,
            tradeData,
            bytes("") /* marketData */, 
            bytes("") /* optionalPermit2 */
        );
        vm.stopPrank();

        // ownership transferred to buyer
        assertEq(IVotingEscrow(VE).ownerOf(tokenId), buyer);

        // seller receives net proceeds and protocol fee is collected in USDC
        assertEq(IERC20(USDC).balanceOf(seller), usdcSellerBefore + price - fee);
        assertEq(IERC20(USDC).balanceOf(feeRecipient), usdcFeeBefore + fee);

        // buyer spent amountIn WETH
        assertEq(wethBuyerBefore - IERC20(WETH).balanceOf(buyer), amountIn);
    }

    function test_success_buyToken_ETHInput_USDCPayment() public {
        uint256 tokenId = 65424;
        (uint256 price, uint256 fee, address payToken) = router.quoteToken(
            RouteLib.BuyRoute.InternalWallet,
            bytes32(0),
            tokenId,
            bytes("")
        );
        assertEq(price, 1_000e6);
        assertEq(payToken, USDC);

        // record balances
        uint256 usdcSellerBefore = IERC20(USDC).balanceOf(seller);
        uint256 usdcFeeBefore = IERC20(USDC).balanceOf(feeRecipient);

        // Build tradeData for mock Odos: swap ETH -> USDC, amountOut = price
        uint256 ethIn = 0.1 ether;
        bytes memory tradeData = abi.encodeWithSelector(
            MockOdosRouterRW.executeSwapETH.selector,
            USDC,
            price
        );

        // buy with native ETH input
        vm.deal(buyer, ethIn);
        vm.startPrank(buyer);
        router.buyToken{value: ethIn}(
            RouteLib.BuyRoute.InternalWallet,
            bytes32(0),
            tokenId,
            address(0),
            price,
            0,
            tradeData,
            bytes("") /* marketData */, 
            bytes("") /* optionalPermit2 */
        );
        vm.stopPrank();

        // ownership transferred to buyer
        assertEq(IVotingEscrow(VE).ownerOf(tokenId), buyer);

        // seller receives net proceeds and protocol fee is collected in USDC
        assertEq(IERC20(USDC).balanceOf(seller), usdcSellerBefore + price - fee);
        assertEq(IERC20(USDC).balanceOf(feeRecipient), usdcFeeBefore + fee);
    }

    // helper for mock to mint USDC
    function mintUsdc(address /*minter*/, address to, uint256 amount) external {
        IUSDC(USDC).mint(to, amount);
    }
}


