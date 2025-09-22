// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DiamondMarketTestBase} from "./utils/DiamondMarketTestBase.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {IMarketRouterFacet} from "src/interfaces/IMarketRouterFacet.sol";
import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {IMarketViewFacet} from "src/interfaces/IMarketViewFacet.sol";
import {IMarketListingsLoanFacet} from "src/interfaces/IMarketListingsLoanFacet.sol";
import {IMarketListingsWalletFacet} from "src/interfaces/IMarketListingsWalletFacet.sol";
import {IMarketOfferFacet} from "src/interfaces/IMarketOfferFacet.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {RouteLib} from "src/libraries/RouteLib.sol";
import {Loan} from "src/LoanV2.sol";
import {Vault} from "src/VaultV2.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ILoan} from "src/interfaces/ILoan.sol";
import {IFlashLoanReceiver} from "src/interfaces/IFlashLoanReceiver.sol";

interface IOwnableMinimal_LM1U { function owner() external view returns (address); }
interface IUSDC_LM1U { function configureMinter(address, uint256) external; function masterMinter() external view returns (address); }
interface IUSDC_Mint_LM1U { function mint(address, uint256) external; function masterMinter() external view returns (address); }

contract LoanV2MarketV1UpgradeTest is DiamondMarketTestBase {
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

        feeRecipient = IOwnableMinimal_LM1U(LOAN_CANONICAL).owner();
        upgradeCanonicalLoan();
        _initMarket(LOAN_CANONICAL, VE, 100, feeRecipient, USDC);
        loan = Loan(LOAN_CANONICAL);

        IMarketConfigFacet(diamond).setAllowedPaymentToken(USDC, true);
        IMarketConfigFacet(diamond).setAllowedPaymentToken(AERO, true);

        // Market fees
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.InternalWallet, 100);
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.InternalLoan, 100);
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.ExternalAdapter, 200);

        // USDC minting for tests and mock Odos setup at canonical address
        vm.prank(IUSDC_LM1U(USDC).masterMinter());
        IUSDC_LM1U(USDC).configureMinter(address(this), type(uint256).max);
    }

    // helper for mock to mint USDC to a recipient (called by ODOS mock)
    function mintUsdc(address /*minter*/, address to, uint256 amount) external {
        IUSDC_Mint_LM1U(USDC).mint(to, amount);
    }

    // Reuse a core happy-path LBO test to ensure parity with RouterLBO
    function test_success_buyTokenWithLBO_AEROInput_USDCListing() public {
        uint256 tokenId = 65424;
        IVotingEscrow ve = IVotingEscrow(VE);
        seller = ve.ownerOf(tokenId);
        vm.assume(seller != address(0));

        // Create a wallet listing (NFT not in loan custody yet) in USDC
        vm.startPrank(seller);
        uint256 listingPrice = 35_000e6;
        ve.approve(diamond, tokenId);
        IMarketListingsWalletFacet(diamond).makeWalletListing(tokenId, listingPrice, USDC, 0, address(0));
        vm.stopPrank();

        // LBO buyer
        address buyer = vm.addr(0x1234);
        uint256 userAeroAmount = 22000e18;
        deal(AERO, buyer, userAeroAmount);

        (uint256 maxLoanPossible,) = ILoan(address(loan)).getMaxLoan(tokenId);
        // Calculate expected amounts
        uint256 upfrontProtocolFee = (listingPrice * IMarketViewFacet(diamond).getLBOProtocolFeeBps()) / 10000;
        uint256 totalNeeded = listingPrice + upfrontProtocolFee;
        uint256 flashLoanAmount = maxLoanPossible - (maxLoanPossible * IMarketViewFacet(diamond).getLBOLenderFeeBps()) / 10000;

        // Build purchase order (internal to router)
        bytes memory purchaseOrderData = abi.encode(
            RouteLib.BuyRoute.InternalWallet,
            bytes32(0),
            tokenId,
            USDC,
            listingPrice,
            uint256(0),
            bytes(""),
            bytes(""),
            bytes("")
        );

        // Build trade data for multi-input swap on mocked ODOS address
        // Install minimal mock at canonical ODOS to mint USDC outputs
        bytes memory code = address(new MinimalOdosMock()).code;
        vm.etch(ODOS, code);
        MinimalOdosMock(ODOS).init(address(this));

        bytes memory tradeData = abi.encodeWithSelector(
            MinimalOdosMock.executeMultiInputSwap.selector,
            AERO,
            userAeroAmount,
            flashLoanAmount,
            totalNeeded
        );

        // Record balances
        uint256 usdcSellerBefore = IERC20(USDC).balanceOf(seller);
        uint256 usdcFeeBefore = IERC20(USDC).balanceOf(feeRecipient);
        uint256 aeroBuyerBefore = IERC20(AERO).balanceOf(buyer);

        // Execute LBO via router
        vm.startPrank(buyer);
        IERC20(AERO).approve(diamond, userAeroAmount);
        IMarketRouterFacet(diamond).buyTokenWithLBO(
            tokenId,
            AERO,
            userAeroAmount,
            purchaseOrderData,
            tradeData,
            bytes("")
        );
        vm.stopPrank();

        // Assertions (parity with RouterLBO)
        (uint256 loanBalance, address borrower) = ILoan(address(loan)).getLoanDetails(tokenId);
        assertEq(borrower, buyer);
        assertTrue(loanBalance > 0);

        // Verify custody and spend
        assertTrue(ve.ownerOf(tokenId) == address(loan));
        assertEq(IERC20(AERO).balanceOf(buyer), aeroBuyerBefore - userAeroAmount);

        // Protocol fees and seller proceeds
        uint256 walletListingFee = (listingPrice * 100) / 10000;
        uint256 feeDelta = IERC20(USDC).balanceOf(feeRecipient) - usdcFeeBefore;
        assertEq(IERC20(USDC).balanceOf(seller), usdcSellerBefore + listingPrice - walletListingFee);
        assertEq(feeDelta, walletListingFee + upfrontProtocolFee);
    }

    function test_success_buyTokenWithLBO_USDCInput_USDCListing_noSwap() public {
        uint256 tokenId = 65424;
        IVotingEscrow ve = IVotingEscrow(VE);
        seller = ve.ownerOf(tokenId);
        vm.assume(seller != address(0));

        // Create a wallet listing (NFT not in loan custody yet) in USDC
        vm.startPrank(seller);
        uint256 listingPrice = 35_000e6;
        ve.approve(diamond, tokenId);
        IMarketListingsWalletFacet(diamond).makeWalletListing(tokenId, listingPrice, USDC, 0, address(0));
        vm.stopPrank();

        // get max loan amount
        (uint256 maxLoanPossible,) = ILoan(address(loan)).getMaxLoan(tokenId);

        // Calculate expected amounts
        uint256 upfrontProtocolFee = (listingPrice * IMarketViewFacet(diamond).getLBOProtocolFeeBps()) / 10000;
        uint256 totalNeeded = listingPrice + upfrontProtocolFee;
        uint256 flashLoanAmount = maxLoanPossible - (maxLoanPossible * IMarketViewFacet(diamond).getLBOLenderFeeBps()) / 10000;

        // LBO buyer
        address buyer = vm.addr(0x1234);
        uint256 userUsdcAmount = totalNeeded - flashLoanAmount;
        deal(USDC, buyer, userUsdcAmount);

        // Build purchase order (internal to router)
        bytes memory purchaseOrderData = abi.encode(
            RouteLib.BuyRoute.InternalWallet,
            bytes32(0),
            tokenId,
            USDC,
            listingPrice,
            uint256(0),
            bytes(""), // No trade data needed for this path
            bytes(""),
            bytes("")
        );

        // Record balances
        uint256 usdcSellerBefore = IERC20(USDC).balanceOf(seller);
        uint256 usdcFeeBefore = IERC20(USDC).balanceOf(feeRecipient);
        uint256 usdcBuyerBefore = IERC20(USDC).balanceOf(buyer);

        // Execute LBO via router with empty tradeData (no swap needed)
        vm.startPrank(buyer);
        IERC20(USDC).approve(diamond, userUsdcAmount);
        IMarketRouterFacet(diamond).buyTokenWithLBO(
            tokenId,
            USDC, // userPaymentAsset is USDC (same as listing)
            userUsdcAmount,
            purchaseOrderData,
            bytes(""), // Empty tradeData triggers no-swap path
            bytes("")
        );
        vm.stopPrank();

        // Assertions
        (uint256 loanBalance, address borrower) = ILoan(address(loan)).getLoanDetails(tokenId);
        assertEq(borrower, buyer);
        assertTrue(loanBalance > 0);

        // Verify custody and spend
        assertTrue(ve.ownerOf(tokenId) == address(loan));
        assertEq(IERC20(USDC).balanceOf(buyer), usdcBuyerBefore - userUsdcAmount);

        // Protocol fees and seller proceeds
        uint256 walletListingFee = (listingPrice * 100) / 10000;
        uint256 feeDelta = IERC20(USDC).balanceOf(feeRecipient) - usdcFeeBefore;
        assertEq(IERC20(USDC).balanceOf(seller), usdcSellerBefore + listingPrice - walletListingFee);
        assertEq(feeDelta, walletListingFee + upfrontProtocolFee);
    }


    // LoanV2-specific: flash fee behavior
    function test_flashFee_zero_for_market_diamond_and_regular_for_others() public {
        uint256 amount = 1_000e6;
        // Market diamond caller: expect zero fee
        vm.prank(diamond);
        uint256 feeMarket = loan.flashFee(USDC, amount);
        assertEq(feeMarket, 0);

        // Random user caller: expect configured fee
        vm.prank(address(0xBEEF));
        uint256 feeOther = loan.flashFee(USDC, amount);
        uint256 expected = (amount * loan.getFlashLoanFee()) / 10000;
        assertEq(feeOther, expected);
    }

    // LoanV2-specific: flashLoan access control and errors through router flow
    // We validate via negative conditions by calling loan directly to assert modifiers/errors
    function test_flashLoan_access_and_errors() public {
        DummyFlashReceiver dummy = new DummyFlashReceiver();

        // Unauthorized caller
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        loan.flashLoan(dummy, USDC, 1000, bytes(""));

        // As market diamond but wrong receiver (must equal market diamond address)
        vm.prank(diamond);
        vm.expectRevert(abi.encodeWithSignature("InvalidFlashLoanReceiver(address)", address(dummy)));
        loan.flashLoan(dummy, USDC, 1000, bytes(""));
    }

    function test_flashLoan_unsupportedToken_reverts() public {
        // Caller is market diamond, receiver must equal market diamond to pass receiver check
        vm.prank(diamond);
        vm.expectRevert(abi.encodeWithSignature("UnsupportedToken(address)", AERO));
        loan.flashLoan(IFlashLoanReceiver(diamond), AERO, 1000, bytes(""));
    }

    function test_flashLoan_exceededMaxLoan_reverts() public {
        uint256 maxAvail = loan.maxFlashLoan(USDC);
        vm.prank(diamond);
        vm.expectRevert(abi.encodeWithSignature("ExceededMaxLoan(uint256)", maxAvail));
        loan.flashLoan(IFlashLoanReceiver(diamond), USDC, maxAvail + 1, bytes(""));
    }


    function test_onlyMarketDiamond_marketNotConfigured_reverts() public {
        // Owner sets market diamond to zero to simulate unconfigured state
        vm.prank(IOwnableMinimal_LM1U(LOAN_CANONICAL).owner());
        loan.setMarketDiamond(address(0));

        // Even calls from the previous diamond should revert at modifier
        vm.prank(diamond);
        vm.expectRevert(abi.encodeWithSignature("MarketNotConfigured()"));
        loan.flashLoan(IFlashLoanReceiver(diamond), USDC, 0, bytes(""));
    }

    function test_finalizeMarketPurchase_zeroBuyer_reverts() public {
        uint256 tokenId = 65424;
        vm.prank(diamond);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        loan.finalizeMarketPurchase(tokenId, address(0), address(0xBEEF));
    }

    function test_finalizeMarketPurchase_invalidListing_reverts() public {
        uint256 tokenId = 65424;
        vm.prank(diamond);
        vm.expectRevert(abi.encodeWithSignature("InvalidListing()"));
        loan.finalizeMarketPurchase(tokenId, address(0xBEEF), address(0xBEEF));
    }

    function test_finalizeMarketPurchase_expiredListing_reverts() public {
        uint256 tokenId = 65424;
        IVotingEscrow ve = IVotingEscrow(VE);
        address realSeller = ve.ownerOf(tokenId);
        vm.assume(realSeller != address(0));

        // Listing that expires immediately
        vm.startPrank(realSeller);
        ve.approve(diamond, tokenId);
        IMarketListingsWalletFacet(diamond).makeWalletListing(tokenId, 10_000e6, USDC, block.timestamp + 1, address(0));
        vm.stopPrank();

        vm.warp(block.timestamp + 2);
        vm.prank(diamond);
        vm.expectRevert(abi.encodeWithSignature("InvalidListing()"));
        loan.finalizeMarketPurchase(tokenId, address(0xBEEF), realSeller);
    }

    function test_finalizeOfferPurchase_invalidOffer_reverts() public {
        uint256 tokenId = 65424;
        uint256 bogusOfferId = type(uint256).max;
        address buyer = address(0xB0B);
        address expectedSeller = address(0xA11CE);
        vm.prank(diamond);
        vm.expectRevert(abi.encodeWithSignature("InvalidOffer()"));
        loan.finalizeOfferPurchase(tokenId, buyer, expectedSeller, bogusOfferId);
    }

    function test_finalizeOfferPurchase_creatorMismatch_reverts() public {
        // Create a real offer where creator != buyer
        uint256 price = 10_000e6;
        address payment = USDC;
        uint256 expiresAt = block.timestamp + 3 days;

        address creator = vm.addr(0xAAA1);
        address buyer = vm.addr(0xBBB2);

        // fund creator for potential fees
        IUSDC_Mint_LM1U(USDC).mint(creator, price);

        // capture logs to retrieve offerId from OfferCreated event
        vm.recordLogs();
        vm.startPrank(creator);
        IMarketOfferFacet(diamond).createOffer(1, 0, price, payment, expiresAt);
        vm.stopPrank();

        // decode OfferCreated(uint256 offerId, address creator, ...)
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("OfferCreated(uint256,address,uint256,uint256,uint256,address,uint256)");
        uint256 offerId = 0;
        for (uint256 i = entries.length; i > 0; i--) {
            if (entries[i-1].topics.length > 0 && entries[i-1].topics[0] == sig) {
                offerId = uint256(entries[i-1].topics[1]);
                break;
            }
        }
        require(offerId != 0, "offer id not found");

        // finalize with buyer != creator triggers CreatorMismatch
        uint256 tokenId = 65424;
        vm.prank(diamond);
        vm.expectRevert(abi.encodeWithSignature("CreatorMismatch()"));
        loan.finalizeOfferPurchase(tokenId, buyer, address(0xA11CE), offerId);
    }

    function test_finalizeOfferPurchase_sellerMismatch_reverts() public {
        // Valid offer by buyer
        uint256 price = 7_500e6;
        address payment = USDC;
        uint256 expiresAt = block.timestamp + 3 days;
        address buyer = vm.addr(0x12345);
        IUSDC_Mint_LM1U(USDC).mint(buyer, price);
        vm.recordLogs();
        vm.startPrank(buyer);
        IMarketOfferFacet(diamond).createOffer(1, 0, price, payment, expiresAt);
        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("OfferCreated(uint256,address,uint256,uint256,uint256,address,uint256)");
        uint256 offerId = 0;
        for (uint256 i = entries.length; i > 0; i--) {
            if (entries[i-1].topics.length > 0 && entries[i-1].topics[0] == sig) {
                offerId = uint256(entries[i-1].topics[1]);
                break;
            }
        }
        require(offerId != 0, "offer id not found");

        uint256 tokenId = 65424;
        // Pass wrong expectedSeller
        vm.prank(diamond);
        vm.expectRevert(abi.encodeWithSignature("SellerMismatch()"));
        loan.finalizeOfferPurchase(tokenId, buyer, address(0xbad), offerId);
    }

    function test_finalizeOfferPurchase_loanNotPaidOff_reverts() public {
        uint256 tokenId = 65424;
        IVotingEscrow ve = IVotingEscrow(VE);
        address seller = ve.ownerOf(tokenId);
        vm.assume(seller != address(0));

        // Put token in Loan custody and create non-zero balance
        vm.startPrank(seller);
        ve.approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 200e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();

        // Valid offer created by buyer (creator == buyer)
        uint256 price = 5_000e6;
        address payment = USDC;
        uint256 expiresAt = block.timestamp + 3 days;
        address buyer = vm.addr(0xB06);
        IUSDC_Mint_LM1U(USDC).mint(buyer, price);
        vm.recordLogs();
        vm.startPrank(buyer);
        IMarketOfferFacet(diamond).createOffer(1, 0, price, payment, expiresAt);
        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("OfferCreated(uint256,address,uint256,uint256,uint256,address,uint256)");
        uint256 offerId = 0;
        for (uint256 i = entries.length; i > 0; i--) {
            if (entries[i-1].topics.length > 0 && entries[i-1].topics[0] == sig) {
                offerId = uint256(entries[i-1].topics[1]);
                break;
            }
        }
        require(offerId != 0, "offer id not found");

        // Now finalize should fail due to loan balance > 0
        vm.prank(diamond);
        vm.expectRevert(abi.encodeWithSignature("LoanNotPaidOff()"));
        loan.finalizeOfferPurchase(tokenId, buyer, seller, offerId);
    }

    function test_finalizeOfferPurchase_expiredOffer_reverts() public {
        // Create an offer that expires immediately and then warp past
        uint256 price = 5_000e6;
        address payment = USDC;
        uint256 expiresAt = block.timestamp + 1;

        address creator = vm.addr(0xCA11);
        IUSDC_Mint_LM1U(USDC).mint(creator, price);

        vm.recordLogs();
        vm.startPrank(creator);
        IMarketOfferFacet(diamond).createOffer(1, 0, price, payment, expiresAt);
        vm.stopPrank();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("OfferCreated(uint256,address,uint256,uint256,uint256,address,uint256)");
        uint256 offerId = 0;
        for (uint256 i = entries.length; i > 0; i--) {
            if (entries[i-1].topics.length > 0 && entries[i-1].topics[0] == sig) {
                offerId = uint256(entries[i-1].topics[1]);
                break;
            }
        }
        require(offerId != 0, "offer id not found");

        vm.warp(block.timestamp + 2);
        uint256 tokenId = 65424;
        address buyer = creator; // satisfy creator==buyer; expiry should still fail
        vm.prank(diamond);
        vm.expectRevert(abi.encodeWithSignature("InvalidOffer()"));
        loan.finalizeOfferPurchase(tokenId, buyer, address(0xA11CE), offerId);
    }

    function test_finalizeMarketPurchase_sellerMismatch_reverts() public {
        uint256 tokenId = 65424;
        IVotingEscrow ve = IVotingEscrow(VE);
        address realSeller = ve.ownerOf(tokenId);
        vm.assume(realSeller != address(0));

        // Create a wallet listing owned by realSeller
        vm.startPrank(realSeller);
        ve.approve(diamond, tokenId);
        IMarketListingsWalletFacet(diamond).makeWalletListing(tokenId, 10_000e6, USDC, 0, address(0));
        vm.stopPrank();

        // Call finalize with mismatching expectedSeller
        address wrongSeller = address(0xDEAD);
        vm.prank(diamond);
        vm.expectRevert(abi.encodeWithSignature("SellerMismatch()"));
        loan.finalizeMarketPurchase(tokenId, address(0xBEEF), wrongSeller);
    }

    function test_finalizeOfferPurchase_zeroBuyer_reverts() public {
        uint256 tokenId = 65424;
        vm.prank(diamond);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        loan.finalizeOfferPurchase(tokenId, address(0), address(0xA11CE), 0);
    }

    function test_finalizeLBOPurchase_unauthorized_reverts() public {
        uint256 tokenId = 65424;
        address buyer = address(0xC0FFEE);
        // Non-market-diamond caller
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        loan.finalizeLBOPurchase(tokenId, buyer);
    }

    function test_finalizeLBOPurchase_zeroBuyer_reverts() public {
        uint256 tokenId = 65424;
        vm.prank(diamond);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        loan.finalizeLBOPurchase(tokenId, address(0));
    }

    function test_flashLoan_paused_reverts() public {
        // Pause flash loans via owner
        vm.prank(IOwnableMinimal_LM1U(LOAN_CANONICAL).owner());
        loan.setFlashLoanPaused(true);

        // Market diamond call should revert with FlashLoansPaused
        vm.prank(diamond);
        vm.expectRevert(abi.encodeWithSignature("FlashLoansPaused()"));
        loan.flashLoan(IFlashLoanReceiver(diamond), USDC, 1, bytes(""));
    }

    function test_finalizeMarketPurchase_loanNotPaidOff_reverts() public {
        uint256 tokenId = 65424;
        IVotingEscrow ve = IVotingEscrow(VE);
        address realSeller = ve.ownerOf(tokenId);
        vm.assume(realSeller != address(0));

        // Create a wallet listing in USDC owned by realSeller
        vm.startPrank(realSeller);
        ve.approve(diamond, tokenId);
        IMarketListingsWalletFacet(diamond).makeWalletListing(tokenId, 10_000e6, USDC, 0, address(0));
        vm.stopPrank();

        // Move token into loan custody and create non-zero balance
        vm.startPrank(realSeller);
        ve.approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 100e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();

        // Finalize call from market diamond should now revert with LoanNotPaidOff
        address buyer = address(0xBEEF);
        vm.prank(diamond);
        vm.expectRevert(abi.encodeWithSignature("LoanNotPaidOff()"));
        loan.finalizeMarketPurchase(tokenId, buyer, realSeller);
    }
}

contract DummyFlashReceiver is IFlashLoanReceiver {
    function onFlashLoan(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes32) {
        // Return non-matching selector to ensure InvalidFlashLoanReceiver path when called.
        return bytes32(uint256(0));
    }
}

contract MinimalOdosMock {
    address public testContract;
    function init(address _testContract) external { testContract = _testContract; }
    function executeMultiInputSwap(address tokenIn, uint256 amountIn, uint256 usdcFromContract, uint256 totalUsdcOut) external returns (bool) {
        address usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(usdc).transferFrom(msg.sender, address(this), usdcFromContract);
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", IUSDC_Mint_LM1U(usdc).masterMinter(), msg.sender, totalUsdcOut));
        require(success, "mint fail");
        return true;
    }
}


