// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IOpenXSwap} from "src/interfaces/external/IOpenXSwap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract OpenXForkTest is Test, IERC721Receiver {
    // Base mainnet RPC
    string internal constant BASE_RPC_URL = "https://mainnet.base.org";

    // Known contracts on Base
    address internal constant MARKET = 0xbDdCf6AB290E7Ad076CA103183730d1Bf0661112; // OpenX market
    address internal constant AERO   = 0x940181a94A35A4569E4529A3CDfB74e38FD98631; // AERO (18d)
    address internal constant veNFT = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4; // veNFT

    // Listing under test
    uint256 internal constant LISTING_ID = 9068;
    uint256 internal constant EXPECTED_TOKEN_ID = 21595; // veNFT tokenId

    function setUp() public virtual {
        vm.createSelectFork(BASE_RPC_URL);
        vm.rollFork(34717107);
    }

    function testListOpenXNFT() public {

        uint256 tokenId = 9069;
        IOpenXSwap market = IOpenXSwap(MARKET);
        // lookup owner of token id 9069 and prank as that address
        address owner = IERC721(veNFT).ownerOf(9069);
        vm.startPrank(owner);

        
        // Approve veNFT to market
        IERC721(veNFT).approve(MARKET, tokenId);

        // Prepare list params
        address[] memory feeRecipients = new address[](0);
        uint256 listPrice = 1e18; // 1 AERO for test
        uint256 startTs = block.timestamp;
        uint256 endTs = startTs + 7 days;

        // List the NFT (we don't assert events here; inspect logs after run)
        market.listNFT(veNFT, tokenId, AERO, listPrice, feeRecipients, startTs, endTs);
        vm.stopPrank();
    }
    function testBuyOpenXListing() public {
        IOpenXSwap market = IOpenXSwap(MARKET);

        (
            address veNft,
            address seller,
            address reservedBuyer,
            uint256 tokenId,
            address currency,
            uint256 price,
            uint256 startTimestamp,
            uint256 endTimestamp,
            bool sold
        ) = market.Listings(LISTING_ID);

        // Basic sanity on listing metadata
        assertEq(currency, AERO, "currency");
        assertEq(tokenId, EXPECTED_TOKEN_ID, "tokenId");
        assertEq(reservedBuyer, address(0), "reservedBuyer");
        assertTrue(block.timestamp >= startTimestamp, "start");
        assertTrue(endTimestamp >= block.timestamp, "end");
        assertFalse(sold, "sold");

        // Fund this test address with exact AERO amount and approve market
        deal(AERO, address(this), price);
        IERC20(AERO).approve(MARKET, price);

        // Execute purchase
        market.buyNFT(LISTING_ID);

        // Verify ownership transferred to this test contract
        assertEq(IERC721(veNft).ownerOf(tokenId), address(this), "ownerOf");

        // Silence warnings on seller var
        seller; // no-op
    }

    // Allow receiving ERC721 safely
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}


