// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DiamondMarketTestBase} from "../utils/DiamondMarketTestBase.t.sol";

import {IMarketListingsWalletFacet} from "src/interfaces/IMarketListingsWalletFacet.sol";
import {IMarketListingsLoanFacet} from "src/interfaces/IMarketListingsLoanFacet.sol";
import {IMarketViewFacet} from "src/interfaces/IMarketViewFacet.sol";
import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {RouteLib} from "src/libraries/RouteLib.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {ILoan} from "src/interfaces/ILoan.sol";
import {Loan} from "src/LoanV2.sol";
import {Vault} from "src/VaultV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseDeploy} from "script/BaseDeploy.s.sol";
import {Errors} from "src/libraries/Errors.sol";

interface IUSDC {
    function approve(address, uint256) external returns (bool);
    function configureMinter(address, uint256) external;
    function mint(address, uint256) external;
    function masterMinter() external view returns (address);
}

contract WalletListingsTest is DiamondMarketTestBase {
    Loan public loan;
    Vault vault;
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20 usdcErc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address user;
    address buyer;
    uint256 walletTokenId;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org", 24353746);
        buyer = vm.addr(0x789);
        // Deploy loan and diamond but do not move walletTokenId into loan custody
        BaseDeploy deployer = new BaseDeploy();
        (loan, vault) = deployer.deployLoan();
        _deployDiamondAndFacets();
        _initMarket(address(loan), address(votingEscrow), 100, 200, 100, 100, address(this), address(usdc));
        // set fees to match expected fees
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.InternalWallet, 100);
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.InternalLoan, 100);
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.ExternalAdapter, 200);

        // Mint USDC to test and fund buyer
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(this), 10_000e6);
        usdcErc.transfer(buyer, 5_000e6);
        usdcErc.approve(diamond, type(uint256).max);

        // pick a token in wallet custody
        walletTokenId = 400;
        user = votingEscrow.ownerOf(walletTokenId);
        vm.assume(user != address(0));
        (, address borrower) = loan.getLoanDetails(walletTokenId);
        vm.assume(borrower == address(0));
    }

    function test_wallet_listing_lifecycle() public {
        vm.startPrank(user);
        IVotingEscrow(address(votingEscrow)).approve(diamond, walletTokenId);
        IMarketListingsWalletFacet(diamond).makeWalletListing(walletTokenId, 100e6, address(usdc), 0, address(0));
        vm.stopPrank();

        (address owner_, uint256 price, address pay,,) = IMarketViewFacet(diamond).getListing(walletTokenId);
        assertEq(owner_, user);
        assertEq(price, 100e6);
        assertEq(pay, address(usdc));

        // Buyer needs approval from the seller to transfer veNFT via market diamond
        vm.startPrank(user);
        IVotingEscrow(address(votingEscrow)).approve(diamond, walletTokenId);
        vm.stopPrank();

        vm.startPrank(buyer);
        usdcErc.approve(diamond, 100e6);
        IMarketListingsWalletFacet(diamond).takeWalletListing(walletTokenId, address(usdc), 100e6, bytes(""), bytes(""));
        vm.stopPrank();

        assertEq(votingEscrow.ownerOf(walletTokenId), buyer);
        (owner_,,,,) = IMarketViewFacet(diamond).getListing(walletTokenId);
        assertEq(owner_, address(0));
    }

    function test_revert_wallet_listing_when_in_loan() public {
        // move to loan custody
        uint256 tokenId = 349;
        address tokenOwner = votingEscrow.ownerOf(tokenId);
        vm.assume(tokenOwner != address(0));
        vm.startPrank(tokenOwner);
        votingEscrow.approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 0, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();

        vm.startPrank(tokenOwner);
        vm.expectRevert();
        IMarketListingsWalletFacet(diamond).makeWalletListing(tokenId, 100e6, address(usdc), 0, address(0));
        vm.stopPrank();
    }

    function test_revert_wallet_listing_when_not_allowed_buyer() public {
        address allowedBuyer = address(0x123);
        vm.startPrank(user);
        // Approval required to list now
        IVotingEscrow(address(votingEscrow)).approve(diamond, walletTokenId);
        IMarketListingsWalletFacet(diamond).makeWalletListing(walletTokenId, 100e6, address(usdc), 0, allowedBuyer);
        vm.stopPrank();

        vm.startPrank(buyer);
        vm.expectRevert();
        IMarketListingsWalletFacet(diamond).takeWalletListing(walletTokenId, address(usdc), 100e6, bytes(""), bytes(""));
        vm.stopPrank();
    }

    function test_success_wallet_listing_when_allowed_buyer() public {
        address allowedBuyer = buyer;
        vm.startPrank(user);
        // Approval required to list now
        IVotingEscrow(address(votingEscrow)).approve(diamond, walletTokenId);
        IMarketListingsWalletFacet(diamond).makeWalletListing(walletTokenId, 100e6, address(usdc), 0, allowedBuyer);
        vm.stopPrank();

        vm.startPrank(buyer);
        usdcErc.approve(diamond, 100e6);
        IMarketListingsWalletFacet(diamond).takeWalletListing(walletTokenId, address(usdc), 100e6, bytes(""), bytes(""));
        vm.stopPrank();
    }

    function test_revert_makeWalletListing_when_not_approved() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Errors.TokenNotApproved.selector));
        IMarketListingsWalletFacet(diamond).makeWalletListing(walletTokenId, 100e6, address(usdc), 0, address(0));
        vm.stopPrank();
    }
}


