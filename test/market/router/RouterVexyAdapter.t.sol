// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DiamondMarketTestBase} from "../../utils/DiamondMarketTestBase.t.sol";
import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {IMarketRouterFacet} from "src/interfaces/IMarketRouterFacet.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {IVexyAdapterFacet} from "src/interfaces/IVexyAdapterFacet.sol";
import {RouteLib} from "src/libraries/RouteLib.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract RouterVexyAdapterTest is DiamondMarketTestBase {
    // Base mainnet addresses
    address constant VEXY = 0x6b478209974BD27e6cf661FEf86C68072b0d6738;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address constant ODOS = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;

    // Provide a known active listing target data at fork height
    uint256 constant FORK_BLOCK = 34121746;
    uint256 constant TARGET_NFT_ID = 5650;

    function setUp() public {
        if (FORK_BLOCK == 0) {
            vm.createSelectFork("https://mainnet.base.org");
        } else {
            vm.createSelectFork("https://mainnet.base.org", FORK_BLOCK);
        }

        _deployDiamondAndFacets();
        // ensure canonical loan proxy is upgraded on fork before market init
        upgradeCanonicalLoan();
        _initMarket(BASE_LOAN_CANONICAL, VOTING_ESCROW, 100, 200, 100, 100, address(this), USDC);

        // Cut in the Vexy adapter facet and register as external adapter with key keccak256("VEXY")
        address vexyFacet = address(new VexyAdapterFacetHarness());
        bytes4[] memory selectors = new bytes4[](2);
        // generic adapter ABI for router
        selectors[0] = bytes4(keccak256("quoteToken(uint256,bytes)"));
        selectors[1] = bytes4(keccak256("buyToken(uint256,uint256,address,uint256,bytes,bytes,bytes)"));
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({facetAddress: vexyFacet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors});
        IDiamondCut(diamond).diamondCut(cut, address(0), "");

        // also ensure generic adapter selectors are available via inheritance
        bytes32 key = keccak256(abi.encodePacked("VEXY"));
        IMarketConfigFacet(diamond).setExternalAdapter(key, vexyFacet);

        // Etch a mock ODOS router that can mint/transfer currency on ETH swaps
        MockOdosRouterRV mock = new MockOdosRouterRV();
        bytes memory code = address(mock).code;
        vm.etch(ODOS, code);

        // External=2% (200 bps)
        IMarketConfigFacet(diamond).setMarketFee(RouteLib.BuyRoute.ExternalAdapter, 200);
    }

    function test_quote_and_buy_via_router_vexy() public {
        // find an active listing for TARGET_NFT_ID on VEXY
        IVexyMarketplace vexy = IVexyMarketplace(VEXY);
        uint256 len = vexy.listingsLength();
        uint256 listingId = type(uint256).max;
        address currency;
        for (uint256 i = len; i > 0; i--) {
            (,,, uint256 nftId, address curr, , , , , uint64 endTime, uint64 soldTime) = vexy.listings(i - 1);
            if (nftId == TARGET_NFT_ID && soldTime == 0 && endTime >= block.timestamp) {
                listingId = i - 1;
                currency = curr;
                break;
            }
        }
        require(listingId != type(uint256).max, "no listing");

        // allow currency and fund buyer
        IMarketConfigFacet(diamond).setAllowedPaymentToken(currency, true);
        address buyer = vm.addr(0xBEEF);
        uint256 price = vexy.listingPrice(listingId);
        deal(currency, buyer, price * 2);

        // quote via router external adapter
        (uint256 p, uint256 fee, address payToken) = IMarketRouterFacet(diamond).quoteToken(
            RouteLib.BuyRoute.ExternalAdapter,
            keccak256(abi.encodePacked("VEXY")),
            0,
            abi.encode(VEXY, listingId)
        );
        assertEq(p, price);
        assertEq(payToken, currency);

        // buy via router (token input)
        vm.startPrank(buyer);
        IERC20(currency).approve(diamond, p + fee);
        bytes memory marketData = abi.encode(VEXY, listingId, currency, p);
        IMarketRouterFacet(diamond).buyToken(
            RouteLib.BuyRoute.ExternalAdapter,
            keccak256(abi.encodePacked("VEXY")),
            0,
            currency,
            p + fee,
            0,
            bytes(""),
            marketData,
            bytes("")
        );
        vm.stopPrank();
    }

    function test_revert_buy_via_router_vexy_ETH_without_tradeData() public {
        // find an active listing
        IVexyMarketplace vexy = IVexyMarketplace(VEXY);
        uint256 len = vexy.listingsLength();
        uint256 listingId = type(uint256).max;
        address currency;
        for (uint256 i = len; i > 0; i--) {
            (,,, uint256 nftId, address curr, , , , , uint64 endTime, uint64 soldTime) = vexy.listings(i - 1);
            if (soldTime == 0 && endTime >= block.timestamp) {
                listingId = i - 1;
                currency = curr;
                break;
            }
        }
        require(listingId != type(uint256).max, "no listing");
        IMarketConfigFacet(diamond).setAllowedPaymentToken(currency, true);

        // quote
        (uint256 p, uint256 fee, ) = IMarketRouterFacet(diamond).quoteToken(
            RouteLib.BuyRoute.ExternalAdapter,
            keccak256(abi.encodePacked("VEXY")),
            0,
            abi.encode(VEXY, listingId)
        );

        // attempt to buy with ETH but no tradeData should revert at router
        address buyer = vm.addr(0xBEEF);
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);
        bytes memory marketData = abi.encode(VEXY, listingId, currency, p);
        vm.expectRevert();
        IMarketRouterFacet(diamond).buyToken{value: 0.1 ether}(
            RouteLib.BuyRoute.ExternalAdapter,
            keccak256(abi.encodePacked("VEXY")),
            0,
            address(0),
            p + fee,
            0,
            bytes(""),
            marketData,
            bytes("")
        );
        vm.stopPrank();
    }

    function test_success_buy_via_router_vexy_ETH_input_swap() public {
        // find an active listing
        IVexyMarketplace vexy = IVexyMarketplace(VEXY);
        uint256 len = vexy.listingsLength();
        uint256 listingId = type(uint256).max;
        address currency;
        for (uint256 i = len; i > 0; i--) {
            (,,, , address curr, , , , , uint64 endTime, uint64 soldTime) = vexy.listings(i - 1);
            if (soldTime == 0 && endTime >= block.timestamp) {
                listingId = i - 1;
                currency = curr;
                break;
            }
        }
        require(listingId != type(uint256).max, "no listing");

        // allow currency
        IMarketConfigFacet(diamond).setAllowedPaymentToken(currency, true);

        // quote
        (uint256 p, uint256 fee, address payToken) = IMarketRouterFacet(diamond).quoteToken(
            RouteLib.BuyRoute.ExternalAdapter,
            keccak256(abi.encodePacked("VEXY")),
            0,
            abi.encode(VEXY, listingId)
        );
        assertEq(payToken, currency);
        uint256 total = p + fee;

        // fund mock ODOS with currency so it can transfer to diamond on ETH swap
        deal(currency, ODOS, total);

        // prepare buyer and tradeData
        address buyer = vm.addr(0xC0FFEE);
        vm.deal(buyer, 1 ether);
        bytes memory marketData = abi.encode(VEXY, listingId, currency, p);
        bytes memory tradeData = abi.encodeWithSelector(
            MockOdosRouterRV.executeSwapETH.selector,
            currency,
            total
        );

        // buy with ETH input
        vm.startPrank(buyer);
        IMarketRouterFacet(diamond).buyToken{value: 0.2 ether}(
            RouteLib.BuyRoute.ExternalAdapter,
            keccak256(abi.encodePacked("VEXY")),
            0,
            address(0),
            total,
            0,
            tradeData,
            marketData,
            bytes("")
        );
        vm.stopPrank();
    }
}

import {VexyAdapterFacet} from "src/facets/market/VexyAdapterFacet.sol";
import {IVexyMarketplace} from "src/interfaces/external/IVexyMarketplace.sol";
import {IDiamondCut} from "src/libraries/LibDiamond.sol";
contract VexyAdapterFacetHarness is VexyAdapterFacet {}


// Minimal mock that simulates ODOS ETH-in swap by transferring currency tokens from itself to msg.sender
contract MockOdosRouterRV {
    function executeSwapETH(address tokenOut, uint256 amountOut) external payable returns (bool) {
        require(msg.value > 0, "no eth");
        IERC20(tokenOut).transfer(msg.sender, amountOut);
        return true;
    }
}

