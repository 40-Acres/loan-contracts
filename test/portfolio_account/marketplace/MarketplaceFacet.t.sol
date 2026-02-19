// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Setup} from "../utils/Setup.sol";
import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../src/facets/marketplace/PortfolioMarketplace.sol";
import {IMarketplaceFacet} from "../../../src/interfaces/IMarketplaceFacet.sol";
import {UserMarketplaceModule} from "../../../src/facets/account/marketplace/UserMarketplaceModule.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {CollateralManager} from "../../../src/facets/account/collateral/CollateralManager.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {FortyAcresMarketplaceFacet} from "../../../src/facets/account/marketplace/FortyAcresMarketplaceFacet.sol";
import {WalletFacet} from "../../../src/facets/account/wallet/WalletFacet.sol";
import {ERC721ReceiverFacet} from "../../../src/facets/ERC721ReceiverFacet.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";

contract MarketplaceFacetTest is Test, Setup {
    PortfolioMarketplace public portfolioMarketplace;
    PortfolioFactory public _walletFactory;
    FacetRegistry public _walletFacetRegistry;
    address public buyer;
    address public feeRecipient;
    uint256 public constant LISTING_PRICE = 1000e6; // 1000 USDC
    uint256 public constant PROTOCOL_FEE_BPS = 100; // 1%

    function setUp() public override {
        super.setUp();

        buyer = address(0x1234);
        feeRecipient = address(0x5678);

        // Add collateral to portfolio account
        addCollateralViaMulticall(_tokenId);

        // Fund vault for potential borrowing
        deal(address(_usdc), _vault, 100000e6);

        portfolioMarketplace = PortfolioMarketplace(address(MarketplaceFacet(address(_portfolioAccount)).marketplace()));

        // Set protocol fee on marketplace (using marketplace owner)
        address marketplaceOwner = portfolioMarketplace.owner();
        vm.startPrank(marketplaceOwner);
        portfolioMarketplace.setProtocolFee(PROTOCOL_FEE_BPS);
        portfolioMarketplace.setFeeRecipient(feeRecipient);
        vm.stopPrank();

        // Deploy wallet factory for buyer purchases
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (_walletFactory, _walletFacetRegistry) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("wallet")))
        );

        // Register WalletFacet on wallet factory
        WalletFacet walletFacet = new WalletFacet(
            address(_walletFactory),
            address(_portfolioAccountConfig),
            address(_swapConfig)
        );
        bytes4[] memory walletSelectors = new bytes4[](6);
        walletSelectors[0] = WalletFacet.transferERC20.selector;
        walletSelectors[1] = WalletFacet.transferNFT.selector;
        walletSelectors[2] = WalletFacet.receiveERC20.selector;
        walletSelectors[3] = WalletFacet.swap.selector;
        walletSelectors[4] = WalletFacet.enforceCollateralRequirements.selector;
        walletSelectors[5] = WalletFacet.onERC721Received.selector;
        _walletFacetRegistry.registerFacet(address(walletFacet), walletSelectors, "WalletFacet");

        // Register FortyAcresMarketplaceFacet on wallet factory
        FortyAcresMarketplaceFacet fortyAcresFacet = new FortyAcresMarketplaceFacet(
            address(_walletFactory),
            address(_portfolioAccountConfig),
            address(_ve),
            address(portfolioMarketplace)
        );
        bytes4[] memory fortyAcresSelectors = new bytes4[](1);
        fortyAcresSelectors[0] = FortyAcresMarketplaceFacet.buyFortyAcresListing.selector;
        _walletFacetRegistry.registerFacet(address(fortyAcresFacet), fortyAcresSelectors, "FortyAcresMarketplaceFacet");
        vm.stopPrank();

        // Create buyer's wallet portfolio
        vm.startPrank(buyer);
        _walletFactory.createAccount(buyer);
        vm.stopPrank();

        // Fund buyer's wallet portfolio with USDC
        address buyerWallet = _walletFactory.portfolioOf(buyer);
        deal(address(_usdc), buyerWallet, LISTING_PRICE * 2);
    }

    // Helper function to add collateral via PortfolioManager multicall
    function addCollateralViaMulticall(uint256 tokenId) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseCollateralFacet.addCollateral.selector,
            tokenId
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function removeCollateralViaMulticall(uint256 tokenId) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseCollateralFacet.removeCollateral.selector,
            tokenId
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    // Helper function to create listing via PortfolioManager multicall
    function makeListingViaMulticall(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 debtAttached,
        uint256 expiresAt,
        address allowedBuyer
    ) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.makeListing.selector,
            tokenId,
            price,
            paymentToken,
            debtAttached,
            expiresAt,
            allowedBuyer
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    // Helper function to borrow via PortfolioManager multicall
    function borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseLendingFacet.borrow.selector,
            amount
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    // Helper function to purchase listing via wallet factory's FortyAcresMarketplaceFacet
    function purchaseListingViaMulticall(
        address buyerEoa,
        address sellerPortfolio,
        uint256 tokenId,
        uint256 price
    ) internal {
        uint256 nonce = portfolioMarketplace.getListing(sellerPortfolio, tokenId).nonce;
        address buyerWallet = _walletFactory.portfolioOf(buyerEoa);
        // Ensure buyer's wallet has sufficient balance
        if (IERC20(_usdc).balanceOf(buyerWallet) < price) {
            deal(address(_usdc), buyerWallet, price);
        }
        vm.startPrank(buyerEoa);
        address[] memory pf = new address[](1);
        pf[0] = address(_walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            sellerPortfolio,
            tokenId,
            nonce
        );
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function testCreateListing() public {
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0, // no debt attached
            0, // never expires
            address(0) // no buyer restriction
        );

        // Verify local sale authorization
        (uint256 price, address paymentToken) = IMarketplaceFacet(_portfolioAccount).getSaleAuthorization(_tokenId);
        assertEq(price, LISTING_PRICE);
        assertEq(paymentToken, address(_usdc));

        // Verify centralized listing
        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(_portfolioAccount, _tokenId);
        assertEq(listing.price, LISTING_PRICE);
        assertEq(listing.paymentToken, address(_usdc));
        assertEq(listing.debtAttached, 0);
        assertEq(listing.expiresAt, 0);
        assertEq(listing.allowedBuyer, address(0));
    }

    function testCreateListingWithDebtAttached() public {
        // Borrow first so the account has actual debt
        uint256 debtAmount = 500e6;
        borrowViaMulticall(debtAmount);

        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            debtAmount,
            0,
            address(0)
        );

        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(_portfolioAccount, _tokenId);
        assertEq(listing.debtAttached, debtAmount);
    }

    function testCannotListWithDebtExceedingActualDebt() public {
        // Borrow a small amount
        uint256 borrowAmount = 100e6;
        borrowViaMulticall(borrowAmount);

        // Try to list with debtAttached exceeding actual debt — should revert
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.makeListing.selector,
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            borrowAmount * 10, // 10x actual debt
            0,
            address(0)
        );
        vm.expectRevert("Debt exceeds actual debt");
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testCannotListWithDebtWhenNoDebt() public {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.makeListing.selector,
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            500e6, // debt attached but no actual debt
            0,
            address(0)
        );
        vm.expectRevert("Debt exceeds actual debt");
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testCreateListingWithExpiration() public {
        uint256 expiresAt = block.timestamp + 7 days;
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0,
            expiresAt,
            address(0)
        );

        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(_portfolioAccount, _tokenId);
        assertEq(listing.expiresAt, expiresAt);
    }

    function testCreateListingWithAllowedBuyer() public {
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0,
            0,
            buyer
        );

        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(_portfolioAccount, _tokenId);
        assertEq(listing.allowedBuyer, buyer);
    }

    function testPurchaseListing() public {
        // Create listing
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0,
            0,
            address(0)
        );

        IERC20 usdc = IERC20(_usdc);
        address buyerWallet = _walletFactory.portfolioOf(buyer);
        uint256 buyerWalletBalanceBefore = usdc.balanceOf(buyerWallet);
        uint256 sellerBalanceBefore = usdc.balanceOf(_user);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        // Purchase listing via wallet factory
        purchaseListingViaMulticall(buyer, _portfolioAccount, _tokenId, LISTING_PRICE);

        // Verify NFT transferred to buyer's wallet portfolio
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), buyerWallet, "NFT should be in buyer's wallet");

        // Verify payment distribution
        uint256 sellerReceived = usdc.balanceOf(_user) - sellerBalanceBefore;
        uint256 feeReceived = usdc.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        uint256 buyerWalletSpent = buyerWalletBalanceBefore - usdc.balanceOf(buyerWallet);

        uint256 expectedProtocolFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        uint256 paymentAfterFee = LISTING_PRICE - expectedProtocolFee;

        assertEq(feeReceived, expectedProtocolFee, "Fee recipient should receive protocol fee");
        assertEq(sellerReceived, paymentAfterFee, "Seller should receive payment minus protocol fee when no debt");
        assertEq(buyerWalletSpent, LISTING_PRICE, "Buyer wallet should spend listing price");

        // Verify sale authorization is removed
        assertFalse(IMarketplaceFacet(_portfolioAccount).hasSaleAuthorization(_tokenId), "Sale authorization should be removed");

        // Verify centralized listing is removed
        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(_portfolioAccount, _tokenId);
        assertEq(listing.owner, address(0), "Centralized listing should be removed");
    }

    function testPurchaseListingWithDebtPaydown() public {
        // Borrow some funds first
        uint256 borrowAmount = 300e6;
        borrowViaMulticall(borrowAmount);

        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(totalDebt, 0, "Should have debt");

        // Create listing without debt attached (debt will be paid from sale proceeds)
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0, // no debt attached — proceeds pay debt
            0,
            address(0)
        );

        IERC20 usdc = IERC20(_usdc);
        uint256 sellerBalanceBefore = usdc.balanceOf(_user);

        // Purchase listing via wallet factory
        purchaseListingViaMulticall(buyer, _portfolioAccount, _tokenId, LISTING_PRICE);

        // Verify debt is reduced (paid down from sale proceeds to maintain collateral standing)
        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();
        // With only one NFT and debt, all debt must be paid to remove collateral
        assertEq(debtAfter, 0, "Seller should have no debt after sale (single NFT)");

        // Get buyer's wallet portfolio
        address buyerWallet = _walletFactory.portfolioOf(buyer);

        // Verify NFT transferred to buyer's wallet
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), buyerWallet, "NFT should be in buyer's wallet");
    }

    function testPurchaseListingWithRestrictedBuyer() public {
        // Create listing with buyer restriction
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0,
            0,
            buyer
        );

        // Purchase by allowed buyer should succeed
        purchaseListingViaMulticall(buyer, _portfolioAccount, _tokenId, LISTING_PRICE);

        // Get buyer's wallet portfolio
        address buyerWallet = _walletFactory.portfolioOf(buyer);

        // Verify NFT transferred to buyer's wallet
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), buyerWallet, "NFT should be in buyer's wallet");
    }

    function testRevertPurchaseListingByRestrictedBuyer() public {
        address otherBuyer = address(0x9999);

        // Create wallet portfolio for otherBuyer
        vm.prank(otherBuyer);
        _walletFactory.createAccount(otherBuyer);
        address otherBuyerWallet = _walletFactory.portfolioOf(otherBuyer);

        // Fund otherBuyer's wallet
        deal(address(_usdc), otherBuyerWallet, LISTING_PRICE);

        // Create listing with buyer restriction
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0,
            0,
            buyer
        );

        uint256 nonce = portfolioMarketplace.getListing(_portfolioAccount, _tokenId).nonce;

        // Purchase by non-allowed buyer should fail
        vm.startPrank(otherBuyer);
        address[] memory pf = new address[](1);
        pf[0] = address(_walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            _portfolioAccount,
            _tokenId,
            nonce
        );
        vm.expectRevert(PortfolioMarketplace.BuyerNotAllowed.selector);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function testRevertPurchaseExpiredListing() public {
        // Create listing with expiration
        uint256 expiresAt = block.timestamp + 1 days;
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0,
            expiresAt,
            address(0)
        );

        uint256 nonce = portfolioMarketplace.getListing(_portfolioAccount, _tokenId).nonce;

        // Fast forward past expiration
        vm.warp(expiresAt + 1);

        // Purchase should fail
        vm.startPrank(buyer);
        address[] memory pf = new address[](1);
        pf[0] = address(_walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            _portfolioAccount,
            _tokenId,
            nonce
        );
        vm.expectRevert(PortfolioMarketplace.ListingExpired.selector);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function testRevertPurchaseWithInsufficientBalance() public {
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0,
            0,
            address(0)
        );

        uint256 nonce = portfolioMarketplace.getListing(_portfolioAccount, _tokenId).nonce;
        address buyerWallet = _walletFactory.portfolioOf(buyer);

        // Drain buyer wallet balance to make it insufficient
        deal(address(_usdc), buyerWallet, LISTING_PRICE - 1);

        vm.startPrank(buyer);
        address[] memory pf = new address[](1);
        pf[0] = address(_walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            _portfolioAccount,
            _tokenId,
            nonce
        );
        vm.expectRevert("Insufficient balance");
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function testRevertPurchaseNonExistentListing() public {
        // Try to purchase without creating listing
        vm.startPrank(buyer);
        address[] memory pf = new address[](1);
        pf[0] = address(_walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            _portfolioAccount,
            _tokenId,
            uint256(0) // nonce doesn't matter — listing doesn't exist
        );
        vm.expectRevert("Listing does not exist");
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function testCancelListing() public {
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0,
            0,
            address(0)
        );

        // Cancel listing
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.cancelListing.selector,
            _tokenId
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();

        // Verify local sale authorization removed
        assertFalse(IMarketplaceFacet(_portfolioAccount).hasSaleAuthorization(_tokenId), "Sale authorization should be removed");

        // Verify centralized listing removed
        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(_portfolioAccount, _tokenId);
        assertEq(listing.owner, address(0), "Centralized listing should be removed");
    }

    function testRevertCancelListingWhenNoListingExists() public {
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.cancelListing.selector,
            _tokenId
        );
        vm.expectRevert();
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testRevertCreateListingWhenListingAlreadyExists() public {
        // Create initial listing
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0,
            0,
            address(0)
        );

        // Try to create another listing for the same token - should revert
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.makeListing.selector,
            _tokenId,
            LISTING_PRICE * 2,
            address(_usdc),
            0,
            0,
            address(0)
        );
        vm.expectRevert("Listing already exists");
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testGetListing() public {
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0,
            0,
            address(0)
        );

        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(
            _portfolioAccount,
            _tokenId
        );

        assertEq(listing.price, LISTING_PRICE);
        assertEq(listing.paymentToken, address(_usdc));
    }

    function testCannotRemoveCollateralWhenListed() public {
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0,
            0,
            address(0)
        );

        vm.expectRevert(abi.encodeWithSelector(BaseCollateralFacet.ListingActive.selector, _tokenId));
        removeCollateralViaMulticall(_tokenId);
    }

    // ============ Protocol Fee Tests ============

    function testProtocolFeeIsCalculatedCorrectly() public {
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0,
            0,
            address(0)
        );

        uint256 feeRecipientBalanceBefore = IERC20(_usdc).balanceOf(feeRecipient);
        uint256 expectedProtocolFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;

        purchaseListingViaMulticall(buyer, _portfolioAccount, _tokenId, LISTING_PRICE);

        uint256 feeReceived = IERC20(_usdc).balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertEq(feeReceived, expectedProtocolFee, "Fee recipient should receive correct protocol fee");
    }

    function testProtocolFeeIsDeductedFromPayment() public {
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0,
            0,
            address(0)
        );

        uint256 sellerBalanceBefore = IERC20(_usdc).balanceOf(_user);
        uint256 feeRecipientBalanceBefore = IERC20(_usdc).balanceOf(feeRecipient);

        purchaseListingViaMulticall(buyer, _portfolioAccount, _tokenId, LISTING_PRICE);

        uint256 expectedProtocolFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        uint256 expectedPaymentToSeller = LISTING_PRICE - expectedProtocolFee;

        uint256 sellerReceived = IERC20(_usdc).balanceOf(_user) - sellerBalanceBefore;
        uint256 feeReceived = IERC20(_usdc).balanceOf(feeRecipient) - feeRecipientBalanceBefore;

        assertEq(sellerReceived, expectedPaymentToSeller, "Seller should receive payment minus protocol fee");
        assertEq(feeReceived, expectedProtocolFee, "Fee recipient should receive protocol fee");
        assertEq(sellerReceived + feeReceived, LISTING_PRICE, "Total distribution should equal listing price");
    }

    function testProtocolFeeWithDifferentFeePercentage() public {
        uint256 newFeeBps = 250;
        address marketplaceOwner = portfolioMarketplace.owner();
        vm.startPrank(marketplaceOwner);
        portfolioMarketplace.setProtocolFee(newFeeBps);
        vm.stopPrank();

        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0,
            0,
            address(0)
        );

        uint256 sellerBalanceBefore = IERC20(_usdc).balanceOf(_user);
        uint256 feeRecipientBalanceBefore = IERC20(_usdc).balanceOf(feeRecipient);

        purchaseListingViaMulticall(buyer, _portfolioAccount, _tokenId, LISTING_PRICE);

        uint256 expectedProtocolFee = (LISTING_PRICE * newFeeBps) / 10000;
        uint256 expectedPaymentToSeller = LISTING_PRICE - expectedProtocolFee;

        uint256 sellerReceived = IERC20(_usdc).balanceOf(_user) - sellerBalanceBefore;
        uint256 feeReceived = IERC20(_usdc).balanceOf(feeRecipient) - feeRecipientBalanceBefore;

        assertEq(sellerReceived, expectedPaymentToSeller, "Seller should receive payment minus 2.5% protocol fee");
        assertEq(feeReceived, expectedProtocolFee, "Fee recipient should receive 2.5% protocol fee");
    }

    function testProtocolFeeWithZeroFee() public {
        address marketplaceOwner = portfolioMarketplace.owner();
        vm.startPrank(marketplaceOwner);
        portfolioMarketplace.setProtocolFee(0);
        vm.stopPrank();

        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0,
            0,
            address(0)
        );

        uint256 sellerBalanceBefore = IERC20(_usdc).balanceOf(_user);
        uint256 feeRecipientBalanceBefore = IERC20(_usdc).balanceOf(feeRecipient);

        purchaseListingViaMulticall(buyer, _portfolioAccount, _tokenId, LISTING_PRICE);

        uint256 feeReceived = IERC20(_usdc).balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertEq(feeReceived, 0, "Fee recipient should receive no fee when fee is 0");

        uint256 sellerReceived = IERC20(_usdc).balanceOf(_user) - sellerBalanceBefore;
        assertEq(sellerReceived, LISTING_PRICE, "Seller should receive full payment when protocol fee is 0");
    }

    // ============ Partial Debt Payment Tests ============

    function testPurchaseListingPartialDebtPaymentMultipleNFTs() public {
        address deployer = _portfolioManager.owner();

        vm.startPrank(deployer);
        _loanConfig.setRewardsRate(20000); // 2%
        vm.stopPrank();

        uint256 tokenId2 = 84298;
        address token2Owner = IVotingEscrow(_ve).ownerOf(tokenId2);
        vm.startPrank(token2Owner);
        IVotingEscrow(_ve).transferFrom(token2Owner, _portfolioAccount, tokenId2);
        vm.stopPrank();
        addCollateralViaMulticall(tokenId2);

        (, uint256 maxLoanBothTokens) = CollateralFacet(_portfolioAccount).getMaxLoan();

        address loanContract = _portfolioAccountConfig.getLoanContract();
        address vault = ILoan(loanContract)._vault();
        deal(address(_usdc), vault, (maxLoanBothTokens * 10000) / 8000);

        uint256 collateral2 = CollateralFacet(_portfolioAccount).getLockedCollateral(tokenId2);
        uint256 rewardsRate = _loanConfig.getRewardsRate();
        uint256 multiplier = _loanConfig.getMultiplier();
        uint256 maxLoanToken2Only = (((collateral2 * rewardsRate) / 1000000) * multiplier) / 1e12;

        uint256 borrowAmount = maxLoanToken2Only + (maxLoanBothTokens - maxLoanToken2Only) / 2;
        (uint256 maxLoanAvailable,) = CollateralFacet(_portfolioAccount).getMaxLoan();
        if (borrowAmount > maxLoanAvailable) {
            borrowAmount = maxLoanAvailable;
        }
        borrowViaMulticall(borrowAmount);

        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 expectedRequiredPayment = totalDebt - maxLoanToken2Only;

        uint256 extraForSeller = 500e6;
        uint256 listingPrice = expectedRequiredPayment + extraForSeller;

        makeListingViaMulticall(
            _tokenId,
            listingPrice,
            address(_usdc),
            0,
            0,
            address(0)
        );

        // Fund buyer's wallet
        address buyerWallet = _walletFactory.portfolioOf(buyer);
        deal(address(_usdc), buyerWallet, listingPrice);

        uint256 sellerBalanceBefore = IERC20(_usdc).balanceOf(_user);

        purchaseListingViaMulticall(buyer, _portfolioAccount, _tokenId, listingPrice);

        uint256 expectedProtocolFee = (listingPrice * PROTOCOL_FEE_BPS) / 10000;
        uint256 paymentAfterFee = listingPrice - expectedProtocolFee;

        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(debtAfter, 0, "Seller should still have some debt remaining");
        assertEq(debtAfter, maxLoanToken2Only, "Debt should be reduced to maxLoanToken2Only");

        uint256 sellerReceived = IERC20(_usdc).balanceOf(_user) - sellerBalanceBefore;
        assertEq(sellerReceived, paymentAfterFee - expectedRequiredPayment, "Seller should receive payment minus fee minus required debt payment");

        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), buyerWallet, "NFT should be in buyer's wallet");
    }

    // ============ Cross-Factory Purchase Test ============

    function testCrossFactoryPurchase() public {
        // Deploy a second aerodrome-style factory from the same PortfolioManager
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factory2, FacetRegistry facetRegistry2) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("cross-factory-test")))
        );

        // Register minimum required facets on factory2 using the SAME marketplace
        // 1. CollateralFacet
        CollateralFacet collateralFacet2 = new CollateralFacet(
            address(factory2), address(_portfolioAccountConfig), address(_ve)
        );
        bytes4[] memory collateralSelectors = new bytes4[](11);
        collateralSelectors[0] = BaseCollateralFacet.addCollateral.selector;
        collateralSelectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        collateralSelectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        collateralSelectors[3] = BaseCollateralFacet.getUnpaidFees.selector;
        collateralSelectors[4] = BaseCollateralFacet.getMaxLoan.selector;
        collateralSelectors[5] = BaseCollateralFacet.getOriginTimestamp.selector;
        collateralSelectors[6] = BaseCollateralFacet.removeCollateral.selector;
        collateralSelectors[7] = BaseCollateralFacet.removeCollateralTo.selector;
        collateralSelectors[8] = BaseCollateralFacet.getCollateralToken.selector;
        collateralSelectors[9] = BaseCollateralFacet.getLockedCollateral.selector;
        collateralSelectors[10] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        facetRegistry2.registerFacet(address(collateralFacet2), collateralSelectors, "CollateralFacet");

        // 2. MarketplaceFacet
        MarketplaceFacet marketplaceFacet2 = new MarketplaceFacet(
            address(factory2), address(_portfolioAccountConfig), address(_ve), address(portfolioMarketplace)
        );
        bytes4[] memory marketplaceSelectors = new bytes4[](6);
        marketplaceSelectors[0] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        marketplaceSelectors[1] = BaseMarketplaceFacet.makeListing.selector;
        marketplaceSelectors[2] = BaseMarketplaceFacet.cancelListing.selector;
        marketplaceSelectors[3] = BaseMarketplaceFacet.marketplace.selector;
        marketplaceSelectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        marketplaceSelectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        facetRegistry2.registerFacet(address(marketplaceFacet2), marketplaceSelectors, "MarketplaceFacet");

        // 3. ERC721ReceiverFacet
        ERC721ReceiverFacet receiverFacet2 = new ERC721ReceiverFacet();
        bytes4[] memory receiverSelectors = new bytes4[](1);
        receiverSelectors[0] = ERC721ReceiverFacet.onERC721Received.selector;
        facetRegistry2.registerFacet(address(receiverFacet2), receiverSelectors, "ERC721ReceiverFacet");

        vm.stopPrank();

        // Create buyer's wallet for this test
        address crossFactoryBuyer = address(0xCF01);
        vm.prank(crossFactoryBuyer);
        _walletFactory.createAccount(crossFactoryBuyer);
        address buyerWallet = _walletFactory.portfolioOf(crossFactoryBuyer);

        // Fund buyer's wallet with USDC
        deal(address(_usdc), buyerWallet, LISTING_PRICE);

        // Seller creates listing in factory1
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, 0, address(0));

        // Purchase via wallet factory
        uint256 nonce = portfolioMarketplace.getListing(_portfolioAccount, _tokenId).nonce;
        vm.startPrank(crossFactoryBuyer);
        address[] memory pf = new address[](1);
        pf[0] = address(_walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            _portfolioAccount,
            _tokenId,
            nonce
        );
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();

        // Verify NFT transferred to buyer's wallet
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), buyerWallet, "NFT should be in buyer's wallet");

        // Verify payment distribution
        uint256 expectedProtocolFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        assertEq(IERC20(_usdc).balanceOf(buyerWallet), 0, "Buyer wallet should have spent all USDC");
        assertEq(IERC20(_usdc).balanceOf(feeRecipient), expectedProtocolFee, "Fee recipient should have protocol fee");
    }
}
