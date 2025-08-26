// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DiamondMarketTestBase} from "../../utils/DiamondMarketTestBase.t.sol";
import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {IMarketRouterFacet} from "src/interfaces/IMarketRouterFacet.sol";
import {IOpenXSwap} from "src/interfaces/external/IOpenXSwap.sol";
import {RouteLib} from "src/libraries/RouteLib.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {Vm} from "forge-std/Vm.sol";

contract RouterOpenXAdapterTest is DiamondMarketTestBase {
    // Base mainnet addresses
    address constant OPENX = 0xbDdCf6AB290E7Ad076CA103183730d1Bf0661112;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;

    // Deterministic fork height
    uint256 constant FORK_BLOCK = 34717107;

    function setUp() public {
        if (FORK_BLOCK == 0) {
            vm.createSelectFork("https://mainnet.base.org");
        } else {
            vm.createSelectFork("https://mainnet.base.org", FORK_BLOCK);
        }

        _deployDiamondAndFacets();
        upgradeCanonicalLoan();
        _initMarket(BASE_LOAN_CANONICAL, VOTING_ESCROW, 250, address(this), AERO);

        // Cut in the OpenX adapter facet and register as external adapter with key keccak256("OPENX")
        address openxFacet = address(new OpenXAdapterFacetHarness());
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("quoteToken(uint256,bytes)"));
        selectors[1] = bytes4(keccak256("buyToken(uint256,uint256,address,uint256,bytes,bytes,bytes)"));
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({facetAddress: openxFacet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors});
        IDiamondCut(diamond).diamondCut(cut, address(0), "");

        // Register adapter key
        bytes32 key = keccak256(abi.encodePacked("OPENX"));
        IMarketConfigFacet(diamond).setExternalAdapter(key, openxFacet);

        // Cut in an ERC721 receiver facet so the diamond can accept safeTransferFrom
        address recvFacet = address(new ERC721ReceiverFacet());
        bytes4[] memory recvSelectors = new bytes4[](1);
        recvSelectors[0] = bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
        IDiamondCut.FacetCut[] memory recvCut = new IDiamondCut.FacetCut[](1);
        recvCut[0] = IDiamondCut.FacetCut({facetAddress: recvFacet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: recvSelectors});
        IDiamondCut(diamond).diamondCut(recvCut, address(0), "");
    }

    function test_quote_and_buy_via_router_openx() public {
        address buyer = vm.addr(0xBEEF);
        uint256 listingId = 9068;
        (
            address veNft,
            ,
            ,
            uint256 tokenId,
            address currency,
            uint256 price,
            uint256 startTs,
            uint256 endTs,
            bool sold
        ) = IOpenXSwap(OPENX).Listings(listingId);

        assertEq(veNft, VOTING_ESCROW, "veNft");
        assertEq(tokenId, 21595, "tokenId");
        assertEq(currency, AERO, "currency");
        assertTrue(block.timestamp >= startTs, "start");
        assertTrue(endTs >= block.timestamp, "end");
        assertFalse(sold, "sold");

        IMarketConfigFacet(diamond).setAllowedPaymentToken(currency, true);
        (uint256 p, uint256 fee, address payToken) = IMarketRouterFacet(diamond).quoteToken(
            RouteLib.BuyRoute.ExternalAdapter,
            keccak256(abi.encodePacked("OPENX")),
            0,
            abi.encode(OPENX, listingId)
        );
        assertEq(p, price);
        assertEq(payToken, currency);

        // deal tokens to buyer calculated from price and fee in currency
        deal(currency, buyer, price + fee);


        vm.startPrank(buyer);
        IERC20(currency).approve(diamond, p + fee);
        bytes memory marketData = abi.encode(OPENX, listingId, currency, p);
        IMarketRouterFacet(diamond).buyToken(
            RouteLib.BuyRoute.ExternalAdapter,
            keccak256(abi.encodePacked("OPENX")),
            tokenId,
            currency,
            p + fee,
            0,
            bytes(""),
            marketData,
            bytes("")
        );
        vm.stopPrank();

        assertEq(IERC721(VOTING_ESCROW).ownerOf(tokenId), buyer);
    }
}

import {OpenXAdapterFacet} from "src/facets/market/OpenXAdapterFacet.sol";
import {IDiamondCut} from "src/libraries/LibDiamond.sol";
import {ERC721ReceiverFacet} from "src/facets/ERC721ReceiverFacet.sol";
contract OpenXAdapterFacetHarness is OpenXAdapterFacet {}



