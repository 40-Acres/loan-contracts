// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DiamondMarketTestBase} from "../utils/DiamondMarketTestBase.t.sol";
import {IMarketMatchingFacet} from "src/interfaces/IMarketMatchingFacet.sol";
import {IMarketOfferFacet} from "src/interfaces/IMarketOfferFacet.sol";
import {IMarketListingsLoanFacet} from "src/interfaces/IMarketListingsLoanFacet.sol";
import {IMarketViewFacet} from "src/interfaces/IMarketViewFacet.sol";
import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {ILoan} from "src/interfaces/ILoan.sol";
import {Loan} from "src/LoanV2.sol";
import {Vault} from "src/VaultV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseDeploy} from "script/BaseDeploy.s.sol";

interface IUSDC {
    function approve(address, uint256) external returns (bool);
    function configureMinter(address, uint256) external;
    function mint(address, uint256) external;
    function masterMinter() external view returns (address);
}

contract MatchingTest is DiamondMarketTestBase {
    Loan public loan;
    Vault vault;
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20 usdcErc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address user;
    address buyer;
    uint256 tokenId;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org", 24353746);
        buyer = vm.addr(0x456);

        BaseDeploy deployer = new BaseDeploy();
        (loan, vault) = deployer.deployLoan();
        _deployDiamondAndFacets();
        IMarketConfigFacet(diamond).initMarket(address(loan), address(votingEscrow), 250, address(this), address(usdc));
        IMarketConfigFacet(diamond).setAllowedPaymentToken(address(usdc), true);
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(buyer, 10_000e6);

        tokenId = 349;
        user = votingEscrow.ownerOf(tokenId);
        vm.assume(user != address(0));

        // Approve market diamond in loan (owner is deployer by default)
        vm.prank(address(deployer));
        loan.setApprovedContract(diamond, true);

        // Move token into Loan custody for loan listing path
        vm.startPrank(user);
        votingEscrow.approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 0, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();
    }

    function test_match_offer_with_loan_listing() public {
        vm.startPrank(user);
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, 2000e6, address(usdc), 0);
        vm.stopPrank();

        vm.startPrank(buyer);
        usdcErc.approve(diamond, 2000e6);
        IMarketOfferFacet(diamond).createOffer(90e21, 100e21, 1000e6, 2000e6, address(usdc), block.timestamp + 7 days);
        vm.stopPrank();

        IMarketMatchingFacet(diamond).matchOfferWithLoanListing(1, tokenId);

        // Listing removed; verify via offer/listing lookups
        (address listingOwner,,,,) = IMarketViewFacet(diamond).getListing(tokenId);
        assertEq(listingOwner, address(0));
    }

    function test_match_offer_with_wallet_listing() public {
        // Use wallet token not in loan custody
        uint256 walletTokenId = 400;
        address walletOwner = votingEscrow.ownerOf(walletTokenId);
        vm.assume(walletOwner != address(0));
        (, address borrower) = ILoan(address(loan)).getLoanDetails(walletTokenId);
        vm.assume(borrower == address(0));

        // Create wallet listing (no outstanding loan)
        vm.startPrank(walletOwner);
        // selector: makeWalletListing(uint256,uint256,address,uint256) = 0x19004652
        (bool ok,) = diamond.call(abi.encodeWithSelector(bytes4(0x19004652), walletTokenId, 2000e6, address(usdcErc), 0));
        require(ok, "makeWalletListing failed");
        // Grant approval for market diamond to transfer veNFT
        IVotingEscrow(address(votingEscrow)).approve(diamond, walletTokenId);
        vm.stopPrank();

        // Create matching offer
        vm.startPrank(buyer);
        usdcErc.approve(diamond, 2000e6);
        IMarketOfferFacet(diamond).createOffer(70e21, 80e21, 1000e6, 2000e6, address(usdcErc), block.timestamp + 7 days);
        vm.stopPrank();

        // Match offer with wallet listing
        // selector: matchOfferWithWalletListing(uint256,uint256) = 0xacc70da7
        (ok,) = diamond.call(abi.encodeWithSelector(bytes4(0xacc70da7), 1, walletTokenId));
        require(ok, "matchOfferWithWalletListing failed");

        // Listing removed
        (address listingOwner2,,,,) = IMarketViewFacet(diamond).getListing(walletTokenId);
        assertEq(listingOwner2, address(0));
    }
}


