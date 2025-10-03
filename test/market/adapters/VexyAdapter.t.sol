// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DiamondMarketTestBase} from "../../utils/DiamondMarketTestBase.t.sol";
import {IVexyAdapterFacet} from "src/interfaces/IVexyAdapterFacet.sol";
import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {Loan} from "src/LoanV2.sol";
import {Vault} from "src/VaultV2.sol";
import {BaseDeploy} from "script/BaseDeploy.s.sol";
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVexyMarketplace} from "src/interfaces/external/IVexyMarketplace.sol";
import {IMarketOfferFacet} from "src/interfaces/IMarketOfferFacet.sol";
import {IMarketMatchingFacet} from "src/interfaces/IMarketMatchingFacet.sol";
import {IMarketViewFacet} from "src/interfaces/IMarketViewFacet.sol";
import {FeeLib} from "src/libraries/FeeLib.sol";
import {RouteLib} from "src/libraries/RouteLib.sol";

interface IUSDC {
    function masterMinter() external view returns (address);
    function configureMinter(address, uint256) external;
    function mint(address, uint256) external;
}

contract VexyAdapterTest is DiamondMarketTestBase {
    // Base mainnet
    address constant VEXY = 0x6b478209974BD27e6cf661FEf86C68072b0d6738;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    IVotingEscrow constant VOTING_ESCROW = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);

    // Provide these
    // Use latest block to ensure code is present at provided addresses
    uint256 constant FORK_BLOCK = 34121746; 
    uint256 constant TARGET_NFT_ID = 5650; // provided
    address constant CURRENCY_WHALE = 0x807877258B55BfEfaBDD469dA1C72731C5070839; // AERO whale

    Loan loan;
    Vault vault;
    address buyer;

    function setUp() public {
        if (FORK_BLOCK == 0) {
            vm.createSelectFork("https://mainnet.base.org");
        } else {
            vm.createSelectFork("https://mainnet.base.org", FORK_BLOCK);
        }
        buyer = vm.addr(0xBEEF);

        _deployDiamondAndFacets();

        // ensure canonical loan proxy is upgraded on fork before market init
        upgradeCanonicalLoan();
        IMarketConfigFacet(diamond).initMarket(address(loan), address(VOTING_ESCROW), 100, 200, 100, 100, address(this), USDC);

        // Cut in the Vexy adapter facet with uniform adapter selectors
        address vexyFacet = address(new VexyAdapterFacetHarness());
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = IVexyAdapterFacet.takeVexyListing.selector;
        selectors[1] = bytes4(keccak256("quoteToken(uint256,bytes)"));
        selectors[2] = bytes4(keccak256("buyToken(uint256,uint256,address,uint256,bytes,bytes,bytes)"));
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: vexyFacet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });
        IDiamondCut(diamond).diamondCut(cut, address(0), "");

        // Register VEXY adapter key for router/matching usage
        IMarketConfigFacet(diamond).setExternalAdapter(keccak256(abi.encodePacked("VEXY")), vexyFacet);

        // Ensure new matching selector is cut in (in case base didn't include it yet)
        address matchingFacet = address(new MarketMatchingFacetHarness());
        bytes4[] memory sel2 = new bytes4[](1);
        sel2[0] = IMarketMatchingFacet.matchOfferWithVexyListing.selector;
        IDiamondCut.FacetCut[] memory cut2 = new IDiamondCut.FacetCut[](1);
        cut2[0] = IDiamondCut.FacetCut({
            facetAddress: matchingFacet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: sel2
        });
        IDiamondCut(diamond).diamondCut(cut2, address(0), "");
    }

    function test_match_offer_with_vexy_listing() public {
        IVexyMarketplace vexy = IVexyMarketplace(VEXY);
        // Find the latest active listing for TARGET_NFT_ID
        uint256 len = vexy.listingsLength();
        uint256 listingId = type(uint256).max;
        address nftCollection;
        uint256 nftId;
        address currency;
        uint64 endTime;
        uint64 soldTime;

        for (uint256 i = len; i > 0; i--) {
            (,, nftCollection, nftId, currency, , , , , endTime, soldTime) = vexy.listings(i - 1);
            if (nftId == TARGET_NFT_ID && soldTime == 0 && endTime >= block.timestamp) {
                listingId = i - 1;
                break;
            }
        }
        require(listingId != type(uint256).max, "Target listing not found or inactive");

        uint256 extPrice = vexy.listingPrice(listingId);

        // Allow the currency and fund offer creator (buyer) with enough to cover external price + our fee
        IMarketConfigFacet(diamond).setAllowedPaymentToken(currency, true);
        uint16 bps = IMarketViewFacet(diamond).marketFeeBps(RouteLib.BuyRoute.ExternalAdapter);
        uint256 fee = (extPrice * bps) / 10000;
        uint256 offerPrice = extPrice + fee; // minimal to cover fee per diamond config

        // Fund buyer in listing currency
        if (currency == USDC) {
            IUSDC usdc = IUSDC(USDC);
            vm.prank(usdc.masterMinter());
            usdc.configureMinter(address(this), type(uint256).max);
            usdc.mint(buyer, offerPrice);
        } else {
            vm.prank(CURRENCY_WHALE);
            IERC20(currency).transfer(buyer, offerPrice);
        }

        // Create offer from buyer (debtTolerance=0 since Vexy listings are wallet NFTs with no debt)
        vm.startPrank(buyer);
        IERC20(currency).approve(diamond, offerPrice+fee);
        IMarketOfferFacet(diamond).createOffer({
            minWeight: 1,
            debtTolerance: 0,
            price: offerPrice,
            paymentToken: currency,
            expiresAt: block.timestamp + 7 days
        });
        vm.stopPrank();

        // Match the offer with the external listing (direct-currency path, no swap) as buyer
        vm.startPrank(buyer);
        IMarketMatchingFacet(diamond).matchOfferWithVexyListing(
            1,
            VEXY,
            listingId,
            extPrice,
            currency,
            extPrice + fee,
            0,
            bytes("") /* tradeData */, 
            bytes("") /* optionalPermit2 */
        );
        vm.stopPrank();

        // Buyer should own the NFT now
        assertEq(IVotingEscrow(nftCollection).ownerOf(nftId), buyer);
    }
}

// Deployable facet for adding to the diamond within the test
import {VexyAdapterFacet} from "src/facets/market/VexyAdapterFacet.sol";
contract VexyAdapterFacetHarness is VexyAdapterFacet {}

import {MarketMatchingFacet} from "src/facets/market/MarketMatchingFacet.sol";
contract MarketMatchingFacetHarness is MarketMatchingFacet {}


