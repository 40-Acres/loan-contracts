// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DiamondMarketTestBase} from "../utils/DiamondMarketTestBase.t.sol";
import {IMarketMatchingFacet} from "src/interfaces/IMarketMatchingFacet.sol";
import {IMarketOfferFacet} from "src/interfaces/IMarketOfferFacet.sol";
import {IMarketListingsLoanFacet} from "src/interfaces/IMarketListingsLoanFacet.sol";
import {IMarketListingsWalletFacet} from "src/interfaces/IMarketListingsWalletFacet.sol";
import {IMarketViewFacet} from "src/interfaces/IMarketViewFacet.sol";
import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {RouteLib} from "src/libraries/RouteLib.sol";
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
        loan.setMarketDiamond(diamond);

        // Move token into Loan custody for loan listing path
        vm.startPrank(user);
        votingEscrow.approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 0, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();
    }

    function test_match_offer_with_loan_listing() public {
        vm.startPrank(user);
        IMarketListingsLoanFacet(diamond).makeLoanListing(tokenId, 2000e6, address(usdc), 0, address(0));
        vm.stopPrank();

        vm.startPrank(buyer);
        usdcErc.approve(diamond, 2000e6);
        IMarketOfferFacet(diamond).createOffer(90e21, 100e21, 1000e6, 2000e6, address(usdc), block.timestamp + 7 days);
        vm.stopPrank();

        IMarketMatchingFacet(diamond).matchOfferWithLoanListing(
            1,
            tokenId,
            address(usdcErc),
            2_000e6,
            0,
            bytes("") /* tradeData */, 
            bytes("") /* optionalPermit2 */
        );

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
        IVotingEscrow(address(votingEscrow)).approve(diamond, walletTokenId);
        IMarketListingsWalletFacet(diamond).makeWalletListing(walletTokenId, 2000e6, address(usdcErc), 0, address(0));
        vm.stopPrank();

        // Create matching offer
        vm.startPrank(buyer);
        usdcErc.approve(diamond, 2000e6);
        IMarketOfferFacet(diamond).createOffer(70e21, 80e21, 1000e6, 2000e6, address(usdcErc), block.timestamp + 7 days);
        vm.stopPrank();

        // Match offer with wallet listing via interface
        IMarketMatchingFacet(diamond).matchOfferWithWalletListing(
            1,
            walletTokenId,
            address(usdcErc),
            2_000e6,
            0,
            bytes("") /* tradeData */, 
            bytes("") /* optionalPermit2 */
        );

        // Listing removed
        (address listingOwner2,,,,) = IMarketViewFacet(diamond).getListing(walletTokenId);
        assertEq(listingOwner2, address(0));
    }
}


contract MatchingOpenXExternalTest is DiamondMarketTestBase {
    address constant OPENX = 0xbDdCf6AB290E7Ad076CA103183730d1Bf0661112;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    uint256 constant FORK_BLOCK = 34717107;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org", FORK_BLOCK);
        _deployDiamondAndFacets();
        // Initialize market with canonical loan custodian and real veNFT
        upgradeCanonicalLoan();
        _initMarket(BASE_LOAN_CANONICAL, VOTING_ESCROW, 250, address(this), AERO);
        // set fees to match expected fees
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.InternalWallet, 100);
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.InternalLoan, 100);
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.ExternalAdapter, 200);

        // Ensure the new OpenX matching selector is cut into the diamond
        address mmFacet = address(new MatchingOpenXFacetHarness());
        bytes4[] memory mmSelectors = new bytes4[](1);
        mmSelectors[0] = bytes4(keccak256("matchOfferWithOpenXListing(uint256,address,uint256,uint256,address,uint256,uint256,bytes,bytes)"));
        IDiamondCut.FacetCut[] memory mmCut = new IDiamondCut.FacetCut[](1);
        mmCut[0] = IDiamondCut.FacetCut({facetAddress: mmFacet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: mmSelectors});
        IDiamondCut(diamond).diamondCut(mmCut, address(0), "");

        // Cut in OpenX adapter selector used by matching facet
        address openxFacet = address(new OpenXAdapterFacetHarness());
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("takeOpenXListing(address,uint256,address,uint256)"));
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({facetAddress: openxFacet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors});
        IDiamondCut(diamond).diamondCut(cut, address(0), "");

        // Allow diamond to receive ERC721 transfers
        address recvFacet = address(new ERC721ReceiverFacet());
        bytes4[] memory recvSelectors = new bytes4[](1);
        recvSelectors[0] = bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
        IDiamondCut.FacetCut[] memory recvCut = new IDiamondCut.FacetCut[](1);
        recvCut[0] = IDiamondCut.FacetCut({facetAddress: recvFacet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: recvSelectors});
        IDiamondCut(diamond).diamondCut(recvCut, address(0), "");

        // Allow AERO
        IMarketConfigFacet(diamond).setAllowedPaymentToken(AERO, true);
    }

    function test_match_offer_with_openx_listing() public {
        uint256 listingId = 9068; // known live listing
        (
            address veNft,
            ,
            ,
            uint256 tokenId,
            address currency,
            uint256 price,
            uint256 startTs,
            uint256 endTs,
            uint256 sold
        ) = IOpenXSwap(OPENX).Listings(listingId);

        assertEq(veNft, VOTING_ESCROW, "veNft");
        assertEq(currency, AERO, "currency");
        assertTrue(block.timestamp >= startTs && endTs >= block.timestamp, "active");
        assertEq(sold, 0, "sold");

        // Create a very permissive offer from buyer, denominated in AERO
        address buyer = vm.addr(0xBEEF);
        uint256 fee = (price * IMarketViewFacet(diamond).marketFeeBps(RouteLib.BuyRoute.ExternalAdapter)) / 10000;
        uint256 maxTotal = price + fee;

        // Fund buyer with sufficient AERO to cover price + fee
        deal(AERO, buyer, maxTotal);

        vm.startPrank(buyer);
        IERC20(AERO).approve(diamond, maxTotal);
        IMarketOfferFacet(diamond).createOffer(0, type(uint256).max, 0, maxTotal, AERO, block.timestamp + 7 days);
        vm.stopPrank();

        // Match using direct currency path (no swap)
        IMarketMatchingFacet(diamond).matchOfferWithOpenXListing(
            1,
            OPENX,
            listingId,
            price,
            AERO,
            maxTotal,
            0,
            bytes("") /* tradeData */,
            bytes("") /* optionalPermit2 */
        );

        // Buyer should now own the NFT
        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId), buyer);
    }
}

import {OpenXAdapterFacet} from "src/facets/market/OpenXAdapterFacet.sol";
import {IDiamondCut} from "src/libraries/LibDiamond.sol";
import {ERC721ReceiverFacet} from "src/facets/ERC721ReceiverFacet.sol";
import {IMarketViewFacet} from "src/interfaces/IMarketViewFacet.sol";
import {RouteLib} from "src/libraries/RouteLib.sol";
import {IOpenXSwap} from "src/interfaces/external/IOpenXSwap.sol";
import {IMarketOfferFacet} from "src/interfaces/IMarketOfferFacet.sol";
import {IMarketMatchingFacet} from "src/interfaces/IMarketMatchingFacet.sol";
import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {MarketMatchingFacet} from "src/facets/market/MarketMatchingFacet.sol";
contract OpenXAdapterFacetHarness is OpenXAdapterFacet {}
contract MatchingOpenXFacetHarness is MarketMatchingFacet {}

