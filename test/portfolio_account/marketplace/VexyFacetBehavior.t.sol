// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";

import {VexyFacet} from "../../../src/facets/account/marketplace/VexyFacet.sol";
import {WalletFacet} from "../../../src/facets/account/wallet/WalletFacet.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @dev Minimal mock veNFT registry. VexyFacet only ever calls ownerOf() on the
 *      voting escrow (to assert the purchased veNFT landed in the buyer). The
 *      mock marketplace assigns ownership on buyListing().
 */
contract MockVotingEscrow {
    mapping(uint256 => address) public ownerOf;

    function setOwner(uint256 tokenId, address owner) external {
        ownerOf[tokenId] = owner;
    }
}

/**
 * @dev Minimal mock of the Vexy marketplace matching IVexyMarketplace.
 *      buyListing pulls `price` of `currency` from the caller and assigns the
 *      veNFT to the caller in the mock voting escrow, mirroring the real flow.
 *      `deliver` toggles whether ownership is actually transferred so the
 *      "veNFT not received" guard can be exercised.
 */
contract MockVexyMarketplace {
    struct L {
        address seller;
        uint96 sellerNftNonce;
        address nftCollection;
        uint256 nftId;
        address currency;
        uint96 slopeMax;
        uint256 price;
        uint32 slopeDuration;
        uint32 fixedDuration;
        uint64 endTime;
        uint64 soldTime;
    }

    mapping(uint256 => L) internal _listings;
    MockVotingEscrow public immutable ve;
    bool public deliver = true;

    constructor(MockVotingEscrow _ve) {
        ve = _ve;
    }

    function setListing(uint256 id, L memory l) external {
        _listings[id] = l;
    }

    function setDeliver(bool d) external {
        deliver = d;
    }

    function listingPrice(uint256 id) external view returns (uint256) {
        return _listings[id].price;
    }

    function listings(uint256 id)
        external
        view
        returns (
            address seller,
            uint96 sellerNftNonce,
            address nftCollection,
            uint256 nftId,
            address currency,
            uint96 slopeMax,
            uint256 price,
            uint32 slopeDuration,
            uint32 fixedDuration,
            uint64 endTime,
            uint64 soldTime
        )
    {
        L memory l = _listings[id];
        return (
            l.seller, l.sellerNftNonce, l.nftCollection, l.nftId, l.currency,
            l.slopeMax, l.price, l.slopeDuration, l.fixedDuration, l.endTime, l.soldTime
        );
    }

    function buyListing(uint256 id) external {
        L storage l = _listings[id];
        // Pull payment from the buyer (the portfolio account / msg.sender).
        IERC20(l.currency).transferFrom(msg.sender, address(this), l.price);
        l.soldTime = uint64(block.timestamp);
        if (deliver) {
            ve.setOwner(l.nftId, msg.sender);
        }
    }

    // Unused interface members.
    function listingsLength() external pure returns (uint256) { return 0; }
    function sellerNftNonce(address, address, uint256) external pure returns (uint96) { return 0; }
    function createListing(address, uint256, address, uint256, uint96, uint32, uint32)
        external pure returns (uint256) { return 0; }
}

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/**
 * @title VexyFacetBehavior
 * @dev Behavioral unit tests for VexyFacet.buyVexyListing (previously zero coverage).
 *
 *      VexyFacet hardcodes the Vexy marketplace as an immutable
 *      (0x6b478209974BD27e6cf661FEf86C68072b0d6738). To exercise it as a pure
 *      unit test (no fork), we vm.etch a MockVexyMarketplace at that exact address.
 *      The voting escrow is a constructor arg, so a mock VE is injected directly.
 *
 *      Covers: happy path (sufficient balance -> veNFT received), and the three
 *      key reverts: soldTime != 0 ("Listing sold"), price == 0
 *      ("Invalid listing price"), and insufficient balance ("Insufficient balance").
 */
contract VexyFacetBehavior is Test {
    // Hardcoded Vexy marketplace immutable inside VexyFacet.
    address public constant VEXY = 0x6b478209974BD27e6cf661FEf86C68072b0d6738;

    PortfolioManager public portfolioManager;
    PortfolioFactory public factory;
    FacetRegistry public registry;

    MockVotingEscrow public ve;
    MockUSDC public usdc;
    MockVexyMarketplace public vexyImpl; // template whose runtime code we etch into VEXY

    address public owner = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address public buyer = address(0xB0B);
    address public portfolio;

    uint256 public constant LISTING_ID = 7;
    uint256 public constant NFT_ID = 4242;
    uint256 public constant PRICE = 1_000e6;

    function setUp() public {
        // Absolute, non-trivial timestamp so block.timestamp - 1 != 0 in the
        // "already sold" case and listing endTimes are sane.
        vm.warp(1_900_000_000);

        ve = new MockVotingEscrow();
        usdc = new MockUSDC();

        // Build a mock marketplace bound to our mock VE, then etch its runtime
        // bytecode into the hardcoded Vexy address. Re-running its constructor
        // logic by storing `ve` requires the immutable to land in code, so we
        // deploy at the target via a small two-step: deploy normally, copy code,
        // and replay the `ve` immutable through storage-free design (ve is set
        // via the etched code's own immutable). Because immutables are baked into
        // runtime code, etching the deployed runtime preserves the `ve` binding.
        vexyImpl = new MockVexyMarketplace(ve);
        vm.etch(VEXY, address(vexyImpl).code);
        // etch copies runtime code only -- it does NOT run the constructor, so the
        // `deliver = true` field initializer never executed against VEXY's storage.
        // Set it explicitly so the happy path delivers the veNFT.
        MockVexyMarketplace(VEXY).setDeliver(true);

        // Core stack: manager -> factory + registry.
        vm.startPrank(owner);
        portfolioManager = new PortfolioManager(owner);
        (factory, registry) = portfolioManager.deployFactory(keccak256(abi.encodePacked("velodrome-usdc")));

        // VexyFacet (votingEscrow = mock VE).
        VexyFacet vexyFacet = new VexyFacet(address(factory), address(ve));
        bytes4[] memory vexySel = new bytes4[](1);
        vexySel[0] = VexyFacet.buyVexyListing.selector;
        registry.registerFacet(address(vexyFacet), vexySel, "VexyFacet");

        // WalletFacet supplies enforceCollateralRequirements() (returns true) so
        // the post-multicall collateral check in PortfolioManager.multicall passes
        // for a wallet-style portfolio. swapConfig only needs to be non-zero.
        WalletFacet walletFacet = new WalletFacet(address(factory), address(0x5A0));
        bytes4[] memory walletSel = new bytes4[](2);
        walletSel[0] = WalletFacet.enforceCollateralRequirements.selector;
        walletSel[1] = WalletFacet.onERC721Received.selector;
        registry.registerFacet(address(walletFacet), walletSel, "WalletFacet");
        vm.stopPrank();

        // Buyer's portfolio account.
        portfolio = factory.createAccount(buyer);
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    function _defaultListing() internal view returns (MockVexyMarketplace.L memory l) {
        l.seller = address(0x5E11E2);
        l.nftCollection = address(ve);
        l.nftId = NFT_ID;
        l.currency = address(usdc);
        l.price = PRICE;
        l.endTime = uint64(block.timestamp + 1 days);
        l.soldTime = 0;
    }

    function _setListing(MockVexyMarketplace.L memory l) internal {
        MockVexyMarketplace(VEXY).setListing(LISTING_ID, l);
    }

    function _buyAsBuyer() internal {
        address[] memory factories = new address[](1);
        factories[0] = address(factory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(VexyFacet.buyVexyListing.selector, LISTING_ID);
        vm.prank(buyer);
        portfolioManager.multicall(calls, factories);
    }

    // ─── Happy path ──────────────────────────────────────────────────

    function test_buyVexyListing_happyPath_receivesNFTAndPays() public {
        _setListing(_defaultListing());
        usdc.mint(portfolio, PRICE); // portfolio holds enough to pay

        uint256 portfolioBefore = usdc.balanceOf(portfolio);
        uint256 vexyBefore = usdc.balanceOf(VEXY);
        assertEq(ve.ownerOf(NFT_ID), address(0), "NFT should be unowned before purchase");

        _buyAsBuyer();

        // veNFT delivered to the portfolio account.
        assertEq(ve.ownerOf(NFT_ID), portfolio, "veNFT should be owned by buyer portfolio");

        // Exactly `price` of USDC moved from the portfolio to the marketplace.
        assertEq(usdc.balanceOf(portfolio), portfolioBefore - PRICE, "portfolio should pay exactly price");
        assertEq(usdc.balanceOf(VEXY), vexyBefore + PRICE, "marketplace should receive price");

        // Approval is cleared back to zero after the buy.
        assertEq(usdc.allowance(portfolio, VEXY), 0, "approval should be cleared to zero after purchase");

        // Listing marked sold.
        assertEq(MockVexyMarketplace(VEXY).listingPrice(LISTING_ID), PRICE, "price unchanged");
        (,,,,,,,,,, uint64 soldTime) = MockVexyMarketplace(VEXY).listings(LISTING_ID);
        assertGt(soldTime, 0, "listing should be marked sold");
    }

    function test_buyVexyListing_happyPath_exactBalance() public {
        _setListing(_defaultListing());
        usdc.mint(portfolio, PRICE); // exactly the price, boundary case

        _buyAsBuyer();

        assertEq(ve.ownerOf(NFT_ID), portfolio, "veNFT should be received with exact balance");
        assertEq(usdc.balanceOf(portfolio), 0, "portfolio drained to zero");
    }

    // ─── Reverts ─────────────────────────────────────────────────────

    function test_buyVexyListing_reverts_whenSold() public {
        MockVexyMarketplace.L memory l = _defaultListing();
        l.soldTime = uint64(block.timestamp - 1); // already sold
        _setListing(l);
        usdc.mint(portfolio, PRICE);

        address[] memory factories = new address[](1);
        factories[0] = address(factory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(VexyFacet.buyVexyListing.selector, LISTING_ID);
        vm.prank(buyer);
        vm.expectRevert(bytes("Listing sold"));
        portfolioManager.multicall(calls, factories);
    }

    function test_buyVexyListing_reverts_whenPriceZero() public {
        MockVexyMarketplace.L memory l = _defaultListing();
        l.price = 0; // invalid price
        _setListing(l);
        usdc.mint(portfolio, PRICE);

        address[] memory factories = new address[](1);
        factories[0] = address(factory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(VexyFacet.buyVexyListing.selector, LISTING_ID);
        vm.prank(buyer);
        vm.expectRevert(bytes("Invalid listing price"));
        portfolioManager.multicall(calls, factories);
    }

    function test_buyVexyListing_reverts_whenInsufficientBalance() public {
        _setListing(_defaultListing());
        usdc.mint(portfolio, PRICE - 1); // one wei short

        address[] memory factories = new address[](1);
        factories[0] = address(factory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(VexyFacet.buyVexyListing.selector, LISTING_ID);
        vm.prank(buyer);
        vm.expectRevert(bytes("Insufficient balance"));
        portfolioManager.multicall(calls, factories);
    }

    function test_buyVexyListing_reverts_whenNFTNotDelivered() public {
        _setListing(_defaultListing());
        usdc.mint(portfolio, PRICE);
        MockVexyMarketplace(VEXY).setDeliver(false); // marketplace takes payment but no NFT

        address[] memory factories = new address[](1);
        factories[0] = address(factory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(VexyFacet.buyVexyListing.selector, LISTING_ID);
        vm.prank(buyer);
        vm.expectRevert(bytes("veNFT not received"));
        portfolioManager.multicall(calls, factories);
    }

    function test_buyVexyListing_reverts_whenNotViaMulticall() public {
        _setListing(_defaultListing());
        usdc.mint(portfolio, PRICE);

        // Direct call to the portfolio (not through PortfolioManager.multicall)
        // must be rejected by onlyPortfolioManagerMulticall.
        vm.prank(buyer);
        vm.expectRevert(); // NotPortfolioManagerMulticall
        VexyFacet(portfolio).buyVexyListing(LISTING_ID);
    }
}
