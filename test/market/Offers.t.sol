// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DiamondMarketTestBase} from "../utils/DiamondMarketTestBase.t.sol";
import {IMarketOfferFacet} from "src/interfaces/IMarketOfferFacet.sol";
import {IMarketViewFacet} from "src/interfaces/IMarketViewFacet.sol";
import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {IMarketListingsLoanFacet} from "src/interfaces/IMarketListingsLoanFacet.sol";
import {ILoan} from "src/interfaces/ILoan.sol";
import {Loan} from "src/LoanV2.sol";
import {Vault} from "src/VaultV2.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseDeploy} from "script/BaseDeploy.s.sol";

interface IUSDC {
    function approve(address, uint256) external returns (bool);
    function configureMinter(address, uint256) external;
    function mint(address, uint256) external;
    function masterMinter() external view returns (address);
}

contract OffersTest is DiamondMarketTestBase {
    Loan public loan;
    Vault vault;
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20 usdcErc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address user;
    address buyer;
    uint256 tokenId;

    uint256 constant MIN_WEIGHT = 90e21;
    uint256 constant MAX_WEIGHT = 100e21;
    uint256 constant DEBT_TOLERANCE = 1000e6;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org", 24353746);
        buyer = vm.addr(0x456);

        BaseDeploy deployer = new BaseDeploy();
        (loan, vault) = deployer.deployLoan();
        _deployDiamondAndFacets();
        IMarketConfigFacet(diamond).initMarket(address(loan), address(votingEscrow), 100, 200, 100, 100, address(this), address(usdc));
        IMarketConfigFacet(diamond).setAllowedPaymentToken(address(usdc), true);
        // Approve market contract in loan
        vm.prank(address(deployer));
        loan.setMarketDiamond(diamond);
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(buyer, 10_000e6);

        tokenId = 349;
        user = votingEscrow.ownerOf(tokenId);
        vm.assume(user != address(0));
    }

    function test_create_update_cancel_offer() public {
        vm.startPrank(buyer);
        usdcErc.approve(diamond, 2_500e6);
        IMarketOfferFacet(diamond).createOffer(1000, 200e6, 2000e6, address(usdc), block.timestamp + 7 days);
        IMarketOfferFacet(diamond).updateOffer(1, 1500, 300e6, 2500e6, address(usdc), block.timestamp + 14 days);
        IMarketOfferFacet(diamond).cancelOffer(1);
        vm.stopPrank();

        (address creator,,,,,) = IMarketViewFacet(diamond).getOffer(1);
        assertEq(creator, address(0));
    }

    function test_offer_acceptance_paths() public {
        // Move token into loan custody for loan accept
        vm.startPrank(user);
        votingEscrow.approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 0, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();

        // Create matching offer
        vm.startPrank(buyer);
        usdcErc.approve(diamond, 2_000e6);
        IMarketOfferFacet(diamond).createOffer(90e21, 1_000e6, 2_000e6, address(usdc), block.timestamp + 7 days);
        vm.stopPrank();

        // Accept from loan
        vm.startPrank(user);
        IMarketListingsLoanFacet(diamond); // touch type
        // Using Matching contract paths is separate; here call accept directly via offer facet
        // Note: in split facets, acceptOffer is on Offer facet
        IMarketOfferFacet(diamond).acceptOffer(tokenId, 1, true);
        vm.stopPrank();
        (, address newBorrower) = ILoan(address(loan)).getLoanDetails(tokenId);
        assertEq(newBorrower, buyer);

        // Create wallet token and accept
        uint256 walletTokenId = 400;
        address walletOwner = votingEscrow.ownerOf(walletTokenId);
        vm.assume(walletOwner != address(0));
        (, address borrower) = ILoan(address(loan)).getLoanDetails(walletTokenId);
        vm.assume(borrower == address(0));

        vm.startPrank(buyer);
        usdcErc.approve(diamond, 2_000e6);
        IMarketOfferFacet(diamond).createOffer(70e21, 1_000e6, 2_000e6, address(usdc), block.timestamp + 7 days);
        vm.stopPrank();

        vm.startPrank(walletOwner);
        IVotingEscrow(address(votingEscrow)).approve(diamond, walletTokenId);
        IMarketOfferFacet(diamond).acceptOffer(walletTokenId, 2, false);
        vm.stopPrank();
        assertEq(votingEscrow.ownerOf(walletTokenId), buyer);
    }
}


