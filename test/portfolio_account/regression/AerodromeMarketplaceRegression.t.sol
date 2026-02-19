// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {BaseForkSetup} from "./BaseForkSetup.sol";
import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../src/facets/marketplace/PortfolioMarketplace.sol";
import {IMarketplaceFacet} from "../../../src/interfaces/IMarketplaceFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {FortyAcresMarketplaceFacet} from "../../../src/facets/account/marketplace/FortyAcresMarketplaceFacet.sol";
import {WalletFacet} from "../../../src/facets/account/wallet/WalletFacet.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title AerodromeMarketplaceRegression
 * @dev Verifies MarketplaceFacet and PortfolioMarketplace config wiring,
 *      and that listing/purchase flows work correctly with the deployed system.
 */
contract AerodromeMarketplaceRegression is BaseForkSetup {
    PortfolioFactory public walletFactory;
    FacetRegistry public walletFacetRegistry;

    address public buyer = address(0x1234);
    address public feeRecipient = address(0x5678);
    uint256 public constant LISTING_PRICE = 1000e6; // 1000 USDC
    uint256 public constant PROTOCOL_FEE_BPS = 100; // 1%

    function setUp() public override {
        super.setUp();

        // Add collateral to portfolio account
        _addCollateral(tokenId);

        // Fund vault for potential borrowing
        _fundVault(100_000e6);

        // Configure marketplace
        vm.startPrank(DEPLOYER);
        portfolioMarketplace.setProtocolFee(PROTOCOL_FEE_BPS);
        portfolioMarketplace.setFeeRecipient(feeRecipient);
        portfolioMarketplace.setAllowedPaymentToken(USDC, true);

        // Deploy wallet factory for buyer purchases
        (walletFactory, walletFacetRegistry) = portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("wallet")))
        );

        // Register WalletFacet on wallet factory
        WalletFacet walletFacet = new WalletFacet(
            address(walletFactory), address(portfolioAccountConfig), address(swapConfig)
        );
        bytes4[] memory walletSel = new bytes4[](6);
        walletSel[0] = WalletFacet.transferERC20.selector;
        walletSel[1] = WalletFacet.transferNFT.selector;
        walletSel[2] = WalletFacet.receiveERC20.selector;
        walletSel[3] = WalletFacet.swap.selector;
        walletSel[4] = WalletFacet.enforceCollateralRequirements.selector;
        walletSel[5] = WalletFacet.onERC721Received.selector;
        walletFacetRegistry.registerFacet(address(walletFacet), walletSel, "WalletFacet");

        // Register FortyAcresMarketplaceFacet on wallet factory
        FortyAcresMarketplaceFacet fortyAcresFacet = new FortyAcresMarketplaceFacet(
            address(walletFactory), address(portfolioAccountConfig),
            VOTING_ESCROW, address(portfolioMarketplace)
        );
        bytes4[] memory fortyAcresSel = new bytes4[](1);
        fortyAcresSel[0] = FortyAcresMarketplaceFacet.buyFortyAcresListing.selector;
        walletFacetRegistry.registerFacet(address(fortyAcresFacet), fortyAcresSel, "FortyAcresMarketplaceFacet");
        vm.stopPrank();

        // Create buyer's wallet portfolio and fund it
        vm.prank(buyer);
        walletFactory.createAccount(buyer);
        address buyerWallet = walletFactory.portfolioOf(buyer);
        deal(USDC, buyerWallet, LISTING_PRICE * 2);
    }

    // ─── MarketplaceFacet config wiring ─────────────────────────────

    function testMarketplaceFacetPortfolioFactory() public view {
        assertEq(address(marketplaceFacet._portfolioFactory()), address(portfolioFactory));
    }

    function testMarketplaceFacetPortfolioAccountConfig() public view {
        assertEq(address(marketplaceFacet._portfolioAccountConfig()), address(portfolioAccountConfig));
    }

    function testMarketplaceFacetVotingEscrow() public view {
        assertEq(address(marketplaceFacet._votingEscrow()), VOTING_ESCROW);
    }

    function testMarketplaceFacetMarketplaceAddress() public view {
        assertEq(marketplaceFacet._marketplace(), address(portfolioMarketplace));
    }

    // ─── PortfolioMarketplace config ────────────────────────────────

    function testPortfolioMarketplaceOwner() public view {
        assertEq(portfolioMarketplace.owner(), DEPLOYER);
    }

    function testPortfolioMarketplacePortfolioManager() public view {
        assertEq(address(portfolioMarketplace.portfolioManager()), address(portfolioManager));
    }

    function testPortfolioMarketplaceVotingEscrow() public view {
        assertEq(address(portfolioMarketplace.votingEscrow()), VOTING_ESCROW);
    }

    function testPortfolioMarketplaceProtocolFee() public view {
        assertEq(portfolioMarketplace.protocolFeeBps(), PROTOCOL_FEE_BPS);
    }

    function testPortfolioMarketplaceFeeRecipient() public view {
        assertEq(portfolioMarketplace.feeRecipient(), feeRecipient);
    }

    function testPortfolioMarketplaceAllowedPaymentToken() public view {
        assertTrue(portfolioMarketplace.allowedPaymentTokens(USDC), "USDC should be allowed payment token");
    }

    // ─── Marketplace facet accessible via diamond proxy ─────────────

    function testMarketplaceViewableViaProxy() public view {
        address mktplace = IMarketplaceFacet(portfolioAccount).marketplace();
        assertEq(mktplace, address(portfolioMarketplace), "marketplace() should route through diamond proxy");
    }

    // ─── makeListing works ──────────────────────────────────────────

    function testMakeListingCreatesListing() public {
        _makeListingAsUser(tokenId, LISTING_PRICE, USDC, 0, address(0));

        // Verify local sale authorization
        (uint256 price, address paymentToken) = IMarketplaceFacet(portfolioAccount).getSaleAuthorization(tokenId);
        assertEq(price, LISTING_PRICE);
        assertEq(paymentToken, USDC);

        // Verify centralized listing
        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(tokenId);
        assertEq(listing.price, LISTING_PRICE);
        assertEq(listing.paymentToken, USDC);
        assertEq(listing.owner, portfolioAccount);
    }

    // ─── cancelListing works ────────────────────────────────────────

    function testCancelListingRemovesListing() public {
        _makeListingAsUser(tokenId, LISTING_PRICE, USDC, 0, address(0));
        assertTrue(IMarketplaceFacet(portfolioAccount).hasSaleAuthorization(tokenId));

        // Cancel
        _singleMulticallAsUser(
            abi.encodeWithSelector(BaseMarketplaceFacet.cancelListing.selector, tokenId)
        );

        assertFalse(IMarketplaceFacet(portfolioAccount).hasSaleAuthorization(tokenId), "Authorization should be removed");
        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(tokenId);
        assertEq(listing.owner, address(0), "Centralized listing should be removed");
    }

    // ─── Purchase works ─────────────────────────────────────────────

    function testPurchaseListingTransfersNFT() public {
        _makeListingAsUser(tokenId, LISTING_PRICE, USDC, 0, address(0));

        address buyerWallet = walletFactory.portfolioOf(buyer);
        uint256 sellerBefore = IERC20(USDC).balanceOf(user);
        uint256 feeBefore = IERC20(USDC).balanceOf(feeRecipient);

        _purchaseAsbuyer(buyer, tokenId);

        // NFT should be in buyer's wallet
        assertEq(IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId), buyerWallet, "NFT should be in buyer wallet");

        // Payment distribution
        uint256 expectedFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        uint256 expectedSeller = LISTING_PRICE - expectedFee;

        assertEq(IERC20(USDC).balanceOf(feeRecipient) - feeBefore, expectedFee, "Fee recipient should receive protocol fee");
        assertEq(IERC20(USDC).balanceOf(user) - sellerBefore, expectedSeller, "Seller should receive payment minus fee");

        // Sale authorization removed
        assertFalse(IMarketplaceFacet(portfolioAccount).hasSaleAuthorization(tokenId));
    }

    // ─── Purchase with debt pays down debt ──────────────────────────

    function testPurchaseWithDebtPaysDown() public {
        _borrow(1e6);
        uint256 debtBefore = CollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debtBefore, 1e6);

        _makeListingAsUser(tokenId, LISTING_PRICE, USDC, 0, address(0));

        _purchaseAsbuyer(buyer, tokenId);

        // With single NFT and debt, all debt must be paid to remove collateral
        assertEq(CollateralFacet(portfolioAccount).getTotalDebt(), 0, "Debt should be fully paid");
    }

    // ─── Cannot remove collateral when listed ───────────────────────

    function testCannotRemoveCollateralWhenListed() public {
        _makeListingAsUser(tokenId, LISTING_PRICE, USDC, 0, address(0));

        vm.expectRevert(abi.encodeWithSelector(BaseCollateralFacet.ListingActive.selector, tokenId));
        _singleMulticallAsUser(
            abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId)
        );
    }

    // ─── Internal helpers ───────────────────────────────────────────

    function _makeListingAsUser(
        uint256 _tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt,
        address allowedBuyer
    ) internal {
        _singleMulticallAsUser(
            abi.encodeWithSelector(
                BaseMarketplaceFacet.makeListing.selector,
                _tokenId, price, paymentToken, expiresAt, allowedBuyer
            )
        );
    }

    function _purchaseAsbuyer(address buyerEoa, uint256 _tokenId) internal {
        uint256 nonce = portfolioMarketplace.getListing(_tokenId).nonce;
        vm.prank(buyerEoa);
        address[] memory factories = new address[](1);
        factories[0] = address(walletFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            _tokenId, nonce
        );
        portfolioManager.multicall(calldatas, factories);
    }
}
