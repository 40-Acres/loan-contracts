// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {DiamondMarketTestBase} from "../utils/DiamondMarketTestBase.t.sol";

import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {IMarketViewFacet} from "src/interfaces/IMarketViewFacet.sol";
import {IMarketListingsLoanFacet} from "src/interfaces/IMarketListingsLoanFacet.sol";
import {IMarketOperatorFacet} from "src/interfaces/IMarketOperatorFacet.sol";

import {ILoan} from "src/interfaces/ILoan.sol";
import {Loan} from "src/LoanV2.sol";
import {Vault} from "src/VaultV2.sol";
import {IVoter} from "src/interfaces/IVoter.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseDeploy} from "script/BaseDeploy.s.sol";
import {DeploySwapper} from "script/BaseDeploySwapper.s.sol";
import {Swapper} from "src/Swapper.sol";

interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(address minter, uint256 minterAllowedAmount) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address) external;
    function acceptOwnership() external;
}

contract LoanListingsTest is DiamondMarketTestBase {
    uint256 fork;

    IERC20 aero = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);

    Vault vault;
    Loan public loan;
    address owner;
    address user;
    address buyer;
    uint256 tokenId = 72562;
    Swapper public swapper;

    uint256 constant LISTING_PRICE = 1000e6;

    function setUp() public {
        fork = vm.createFork("https://mainnet.base.org");
        vm.selectFork(fork);
        vm.rollFork(24353746);

        owner = address(this);
        buyer = vm.addr(0x456);

        tokenId = 349;
        user = votingEscrow.ownerOf(tokenId);
        require(user != address(0), "TokenId 349 has no owner");

        BaseDeploy deployer = new BaseDeploy();
        (loan, vault) = deployer.deployLoan();

        vm.startPrank(address(deployer));
        loan.setMultiplier(100000000000);
        loan.setRewardsRate(11300);
        loan.setLenderPremium(2000);
        loan.setProtocolFee(500);

        DeploySwapper swapperDeploy = new DeploySwapper();
        swapper = Swapper(swapperDeploy.deploy());
        loan.setSwapper(address(swapper));

        IOwnable(address(loan)).transferOwnership(owner);
        vm.stopPrank();

        vm.prank(owner);
        IOwnable(address(loan)).acceptOwnership();

        _deployDiamondAndFacets();

        IMarketConfigFacet(diamond).initMarket(address(loan), address(votingEscrow), 250, owner, address(usdc));

        vm.startPrank(owner);
        loan.setApprovedContract(diamond, true);
        IMarketConfigFacet(diamond).setAllowedPaymentToken(address(usdc), true);
        vm.stopPrank();

        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(vault), 10000e6);
        vm.prank(0x122fDD9fEcbc82F7d4237C0549a5057E31c8EF8D);
        usdc.transfer(buyer, 10000e6);

        _createUserLoan();
    }

    function _createUserLoan() internal {
        vm.startPrank(user);
        votingEscrow.approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 100e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();
    }

    function testInitAndConfig() public {
        assertEq(IMarketViewFacet(diamond).marketFeeBps(), 250);
        assertEq(IMarketViewFacet(diamond).feeRecipient(), owner);
        assertTrue(IMarketViewFacet(diamond).allowedPaymentToken(address(usdc)));
    }

    function test_makeListing_Success() public {
        vm.startPrank(user);
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();
        (address owner_, uint256 price, address paymentToken, bool hasOutstandingLoan, uint256 expiresAt) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(owner_, user);
        assertEq(price, LISTING_PRICE);
        assertEq(paymentToken, address(usdc));
        assertTrue(hasOutstandingLoan);
        assertEq(expiresAt, 0);
    }

    function test_updateListing_Success() public {
        vm.startPrank(user);
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();

        uint256 newPrice = 2000e6;
        address newPaymentToken = address(weth);
        uint256 newExpiresAt = block.timestamp + 7 days;

        vm.prank(owner);
        IMarketConfigFacet(diamond).setAllowedPaymentToken(newPaymentToken, true);

        vm.prank(user);
        IMarketListingsLoanFacet(diamond).updateLoanListing(tokenId, newPrice, newPaymentToken, newExpiresAt);

        (, uint256 price, address paymentToken, , uint256 expiresAt) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(price, newPrice);
        assertEq(paymentToken, newPaymentToken);
        assertEq(expiresAt, newExpiresAt);
    }

    function test_cancelListing_Success() public {
        vm.startPrank(user);
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();

        vm.prank(user);
        IMarketListingsLoanFacet(diamond).cancelLoanListing(tokenId);

        (address listingOwner,,,,) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(listingOwner, address(0));
    }

    function test_takeListing_Success_WithOutstandingLoan() public {
        vm.startPrank(user);
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();

        (uint256 totalCost, uint256 listingPrice, uint256 loanBalance, ) = IMarketViewFacet(diamond).getTotalCost(tokenId);
        vm.startPrank(buyer);
        usdc.approve(diamond, totalCost);

        uint16 feeBps = IMarketViewFacet(diamond).marketFeeBps();
        uint256 expectedFee = (listingPrice * feeBps) / 10000;
        uint256 buyerInitial = usdc.balanceOf(buyer);
        uint256 sellerInitial = usdc.balanceOf(user);

        IMarketListingsLoanFacet(diamond).takeLoanListing(tokenId);
        vm.stopPrank();

        (, address newBorrower) = loan.getLoanDetails(tokenId);
        assertEq(newBorrower, buyer);

        assertEq(usdc.balanceOf(buyer), buyerInitial - totalCost);
        assertEq(usdc.balanceOf(user), sellerInitial + listingPrice - expectedFee);
        assertTrue(loanBalance > 0);

        (address listingOwner,,,,) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(listingOwner, address(0));
    }

    function test_RevertWhen_MakeListing_Unauthorized() public {
        vm.startPrank(buyer);
        vm.expectRevert();
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();
    }

    function test_RevertWhen_TakeListing_Nonexistent() public {
        vm.startPrank(buyer);
        usdc.approve(diamond, LISTING_PRICE);
        vm.expectRevert();
        IMarketListingsLoanFacet(diamond).takeLoanListing(999999);
        vm.stopPrank();
    }

    function test_updateListing_RevertWhen_InvalidPaymentToken() public {
        vm.startPrank(user);
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert();
        IMarketListingsLoanFacet(diamond).updateLoanListing(tokenId, LISTING_PRICE, address(0x123), 0);
    }

    function test_isListingActive_RespectsExpiration() public {
        uint256 expirationTime = block.timestamp + 1 hours;
        vm.startPrank(user);
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, LISTING_PRICE, address(usdc), expirationTime);
        vm.stopPrank();

        assertTrue(IMarketViewFacet(diamond).isListingActive(tokenId));
        vm.warp(expirationTime + 1);
        assertFalse(IMarketViewFacet(diamond).isListingActive(tokenId));
    }

    function test_pause_Unpause_BlocksAndAllowsOperations() public {
        IMarketConfigFacet(diamond).pause();
        vm.startPrank(user);
        vm.expectRevert();
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();

        IMarketConfigFacet(diamond).unpause();
        vm.startPrank(user);
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();

        (address owner_,,,,) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(owner_, user);
    }

    function test_setMarketFee_Success_And_RevertWhen_Invalid() public {
        IMarketConfigFacet(diamond).setMarketFee(1000);
        assertEq(IMarketViewFacet(diamond).marketFeeBps(), 1000);
        vm.expectRevert();
        IMarketConfigFacet(diamond).setMarketFee(1001);
    }

    function test_setFeeRecipient_Success_And_RevertWhen_Zero() public {
        address newRecipient = vm.addr(0x777);
        IMarketConfigFacet(diamond).setFeeRecipient(newRecipient);
        assertEq(IMarketViewFacet(diamond).feeRecipient(), newRecipient);
        vm.expectRevert();
        IMarketConfigFacet(diamond).setFeeRecipient(address(0));
    }

    function test_setAllowedPaymentToken_Success_And_Disallow() public {
        IMarketConfigFacet(diamond).setAllowedPaymentToken(address(usdc), false);
        vm.startPrank(user);
        vm.expectRevert();
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();
        IMarketConfigFacet(diamond).setAllowedPaymentToken(address(usdc), true);
    }

    function test_initMarket_RevertWhen_CalledTwice() public {
        vm.expectRevert();
        IMarketConfigFacet(diamond).initMarket(address(loan), address(votingEscrow), 250, owner, address(usdc));
    }

    function test_setAllowedPaymentToken_RevertWhen_ZeroAddress() public {
        vm.expectRevert();
        IMarketConfigFacet(diamond).setAllowedPaymentToken(address(0), true);
    }

    function test_RevertWhen_MakeListing_VeNFTNotInLoanCustody() public {
        uint256 walletTokenId = 400;
        address walletOwner = votingEscrow.ownerOf(walletTokenId);
        vm.assume(walletOwner != address(0));
        (, address borrower) = loan.getLoanDetails(walletTokenId);
        vm.assume(borrower == address(0));

        vm.startPrank(walletOwner);
        vm.expectRevert();
        IMarketListingsLoanFacet(diamond).makeLoanListing(walletTokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();
    }

    function test_takeListing_Success_NoOutstandingLoan() public {
        uint256 newTokenId = 350;
        address newOwner = votingEscrow.ownerOf(newTokenId);
        vm.assume(newOwner != address(0));

        vm.startPrank(newOwner);
        votingEscrow.approve(address(loan), newTokenId);
        loan.requestLoan(newTokenId, 0, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        IMarketListingsLoanFacet(diamond).makeLoanListing(newTokenId, LISTING_PRICE, address(usdc), 0);
        vm.stopPrank();

        (uint256 totalCost, uint256 listingPrice, uint256 loanBalance,) = IMarketViewFacet(diamond).getTotalCost(newTokenId);
        assertEq(totalCost, LISTING_PRICE);
        assertEq(listingPrice, LISTING_PRICE);
        assertEq(loanBalance, 0);

        vm.startPrank(buyer);
        usdc.approve(diamond, LISTING_PRICE);
        IMarketListingsLoanFacet(diamond).takeLoanListing(newTokenId);
        vm.stopPrank();

        (, address newBorrower) = loan.getLoanDetails(newTokenId);
        assertEq(newBorrower, buyer);
    }

    function test_setMarketFee_RevertWhen_NotOwnerOrAdmin() public {
        vm.prank(buyer);
        vm.expectRevert();
        IMarketConfigFacet(diamond).setMarketFee(100);
    }

    function test_UnauthorizedMarketCannotTransferOwnership() public {
        address unauthorizedMarket = vm.addr(0xABC);
        vm.startPrank(unauthorizedMarket);
        vm.expectRevert();
        loan.setBorrower(tokenId, buyer);
        vm.stopPrank();
    }
}


