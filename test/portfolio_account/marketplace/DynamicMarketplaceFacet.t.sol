// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {DynamicLocalSetup} from "../utils/DynamicLocalSetup.sol";
import {DynamicMarketplaceFacet} from "../../../src/facets/account/marketplace/DynamicMarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../src/facets/marketplace/PortfolioMarketplace.sol";
import {IMarketplaceFacet} from "../../../src/interfaces/IMarketplaceFacet.sol";
import {DynamicCollateralFacet} from "../../../src/facets/account/collateral/DynamicCollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {FortyAcresMarketplaceFacet} from "../../../src/facets/account/marketplace/FortyAcresMarketplaceFacet.sol";
import {WalletFacet} from "../../../src/facets/account/wallet/WalletFacet.sol";
import {ERC721ReceiverFacet} from "../../../src/facets/ERC721ReceiverFacet.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";

/**
 * @title DynamicMarketplaceFacetTest
 * @dev Marketplace tests for diamonds using DynamicFeesVault + DynamicMarketplaceFacet.
 *      Local version (no fork) — uses DynamicLocalSetup with MockVotingEscrow.
 *      Key differences from standard MarketplaceFacet tests:
 *      - Debt is tracked in DynamicFeesVault, not locally
 *      - No unpaid fees (getUnpaidFees() always returns 0)
 *      - Sale proceeds pay debt via receiveSaleProceeds (partial paydown)
 */
contract DynamicMarketplaceFacetTest is Test, DynamicLocalSetup {
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

        portfolioMarketplace = PortfolioMarketplace(
            address(DynamicMarketplaceFacet(address(_portfolioAccount)).marketplace())
        );

        // Set protocol fee and allowed payment tokens on marketplace
        address marketplaceOwner = portfolioMarketplace.owner();
        vm.startPrank(marketplaceOwner);
        portfolioMarketplace.setProtocolFee(PROTOCOL_FEE_BPS);
        portfolioMarketplace.setFeeRecipient(feeRecipient);
        portfolioMarketplace.setAllowedPaymentToken(address(_usdc), true);
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

    // ============ Helper Functions ============

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

    function makeListingViaMulticall(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
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
            expiresAt,
            allowedBuyer
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

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

    function purchaseListingViaMulticall(
        address buyerEoa,
        uint256 tokenId,
        uint256 price
    ) internal {
        uint256 nonce = portfolioMarketplace.getListing(tokenId).nonce;
        address buyerWalletPortfolio = _walletFactory.portfolioOf(buyerEoa);
        if (buyerWalletPortfolio == address(0)) {
            buyerWalletPortfolio = _walletFactory.createAccount(buyerEoa);
        }
        if (IERC20(_usdc).balanceOf(buyerWalletPortfolio) < price) {
            deal(address(_usdc), buyerWalletPortfolio, price);
        }
        vm.startPrank(buyerEoa);
        address[] memory pf = new address[](1);
        pf[0] = address(_walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            tokenId,
            nonce
        );
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    // ============ Listing CRUD Tests ============

    function testCreateListing() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        // Verify local sale authorization
        (uint256 price, address paymentToken) = IMarketplaceFacet(_portfolioAccount).getSaleAuthorization(_tokenId);
        assertEq(price, LISTING_PRICE);
        assertEq(paymentToken, address(_usdc));

        // Verify centralized listing
        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(_tokenId);
        assertEq(listing.price, LISTING_PRICE);
        assertEq(listing.paymentToken, address(_usdc));
    }

    function testCreateListingWithExpiration() public {
        uint256 expiresAt = block.timestamp + 7 days;
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), expiresAt, address(0));

        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(_tokenId);
        assertEq(listing.expiresAt, expiresAt);
    }

    function testCreateListingWithAllowedBuyer() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, buyer);

        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(_tokenId);
        assertEq(listing.allowedBuyer, buyer);
    }

    function testCancelListing() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseMarketplaceFacet.cancelListing.selector, _tokenId);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        assertFalse(IMarketplaceFacet(_portfolioAccount).hasSaleAuthorization(_tokenId), "Sale authorization should be removed");
        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(_tokenId);
        assertEq(listing.owner, address(0), "Centralized listing should be removed");
    }

    function testRevertCancelListingWhenNoListingExists() public {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseMarketplaceFacet.cancelListing.selector, _tokenId);
        vm.expectRevert();
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function testRevertCreateListingWhenListingAlreadyExists() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.makeListing.selector, _tokenId, LISTING_PRICE * 2, address(_usdc), 0, address(0)
        );
        vm.expectRevert("Listing already exists");
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function testGetListing() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(_tokenId);
        assertEq(listing.price, LISTING_PRICE);
        assertEq(listing.paymentToken, address(_usdc));
    }

    function testCannotRemoveCollateralWhenListed() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        vm.expectRevert(abi.encodeWithSelector(BaseCollateralFacet.ListingActive.selector, _tokenId));
        removeCollateralViaMulticall(_tokenId);
    }

    // ============ P2P Purchase Tests ============

    function testPurchaseListing() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        uint256 sellerBalanceBefore = IERC20(_usdc).balanceOf(_user);
        uint256 feeRecipientBalanceBefore = IERC20(_usdc).balanceOf(feeRecipient);

        purchaseListingViaMulticall(buyer, _tokenId, LISTING_PRICE);

        address buyerWalletPortfolio = _walletFactory.portfolioOf(buyer);

        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), buyerWalletPortfolio, "NFT should be in buyer's wallet portfolio");

        uint256 expectedProtocolFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        uint256 paymentAfterFee = LISTING_PRICE - expectedProtocolFee;

        uint256 feeReceived = IERC20(_usdc).balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertEq(feeReceived, expectedProtocolFee, "Fee recipient should receive protocol fee");

        uint256 sellerReceived = IERC20(_usdc).balanceOf(_user) - sellerBalanceBefore;
        assertEq(sellerReceived, paymentAfterFee, "Seller should receive payment minus protocol fee");

        // Wallet portfolio should have spent the listing price
        assertEq(IERC20(_usdc).balanceOf(buyerWalletPortfolio), LISTING_PRICE, "Buyer wallet should have remaining balance");

        // Verify both authorizations cleaned up
        assertFalse(IMarketplaceFacet(_portfolioAccount).hasSaleAuthorization(_tokenId), "Sale authorization should be removed");
        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(_tokenId);
        assertEq(listing.owner, address(0), "Centralized listing should be removed");
    }

    function testPurchaseListingWithDebtPaydown() public {
        uint256 borrowAmount = 300e6;
        borrowViaMulticall(borrowAmount);

        uint256 totalDebt = DynamicCollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(totalDebt, 0, "Should have debt");

        // Listing without debt attached — proceeds pay debt via receiveSaleProceeds
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        purchaseListingViaMulticall(buyer, _tokenId, LISTING_PRICE);

        // With only one NFT, all debt must be paid to remove collateral
        uint256 debtAfter = DynamicCollateralFacet(_portfolioAccount).getTotalDebt();
        assertEq(debtAfter, 0, "Seller should have no debt after sale (single NFT)");

        address buyerWalletPortfolio = _walletFactory.portfolioOf(buyer);
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), buyerWalletPortfolio, "NFT should be in buyer's wallet portfolio");
    }

    function testPurchaseListingWithRestrictedBuyer() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, buyer);

        purchaseListingViaMulticall(buyer, _tokenId, LISTING_PRICE);

        address buyerWalletPortfolio = _walletFactory.portfolioOf(buyer);
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), buyerWalletPortfolio, "NFT should be in buyer's wallet portfolio");
    }

    function testRevertPurchaseListingByRestrictedBuyer() public {
        address otherBuyer = address(0x9999);

        address otherBuyerWallet = _walletFactory.createAccount(otherBuyer);
        deal(address(_usdc), otherBuyerWallet, LISTING_PRICE);

        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, buyer);

        uint256 nonce = portfolioMarketplace.getListing(_tokenId).nonce;
        vm.startPrank(otherBuyer);
        address[] memory pf = new address[](1);
        pf[0] = address(_walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            _tokenId,
            nonce
        );
        vm.expectRevert(PortfolioMarketplace.BuyerNotAllowed.selector);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function testRevertPurchaseExpiredListing() public {
        uint256 expiresAt = block.timestamp + 1 days;
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), expiresAt, address(0));

        uint256 nonce = portfolioMarketplace.getListing(_tokenId).nonce;
        vm.warp(expiresAt + 1);

        address buyerWallet = _walletFactory.portfolioOf(buyer);
        deal(address(_usdc), buyerWallet, LISTING_PRICE);
        vm.startPrank(buyer);
        address[] memory pf = new address[](1);
        pf[0] = address(_walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            _tokenId,
            nonce
        );
        vm.expectRevert(PortfolioMarketplace.ListingExpired.selector);
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function testRevertPurchaseWithInsufficientBalance() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        uint256 nonce = portfolioMarketplace.getListing(_tokenId).nonce;
        address buyerWallet = _walletFactory.portfolioOf(buyer);
        // Fund wallet with less than listing price
        deal(address(_usdc), buyerWallet, LISTING_PRICE - 1);
        vm.startPrank(buyer);
        address[] memory pf = new address[](1);
        pf[0] = address(_walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            _tokenId,
            nonce
        );
        vm.expectRevert("Insufficient balance");
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function testRevertPurchaseNonExistentListing() public {
        address buyerWallet = _walletFactory.portfolioOf(buyer);
        deal(address(_usdc), buyerWallet, LISTING_PRICE);
        vm.startPrank(buyer);
        address[] memory pf = new address[](1);
        pf[0] = address(_walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            _tokenId,
            uint256(0)
        );
        vm.expectRevert("Listing does not exist");
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    // ============ Partial Debt Payment Tests (Multiple NFTs) ============

    function testPurchaseListingPartialDebtPaymentMultipleNFTs() public {
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _loanConfig.setRewardsRate(20000); // 2%
        vm.stopPrank();

        // Transfer second token to portfolio and add as collateral
        vm.startPrank(_tokenId2Owner);
        IVotingEscrow(_ve).transferFrom(_tokenId2Owner, _portfolioAccount, _tokenId2);
        vm.stopPrank();
        addCollateralViaMulticall(_tokenId2);

        (, uint256 maxLoanBothTokens) = DynamicCollateralFacet(_portfolioAccount).getMaxLoan();

        uint256 collateral2 = DynamicCollateralFacet(_portfolioAccount).getLockedCollateral(_tokenId2);
        uint256 rewardsRate = _loanConfig.getRewardsRate();
        uint256 multiplier = _loanConfig.getMultiplier();
        uint256 maxLoanToken2Only = (((collateral2 * rewardsRate) / 1000000) * multiplier) / 1e12;

        uint256 borrowAmount = maxLoanToken2Only + (maxLoanBothTokens - maxLoanToken2Only) / 2;
        (uint256 maxLoanAvailable,) = DynamicCollateralFacet(_portfolioAccount).getMaxLoan();
        if (borrowAmount > maxLoanAvailable) {
            borrowAmount = maxLoanAvailable;
        }
        borrowViaMulticall(borrowAmount);

        uint256 totalDebt = DynamicCollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 expectedRequiredPayment = totalDebt - maxLoanToken2Only;

        uint256 extraForSeller = 500e6;
        uint256 listingPrice = expectedRequiredPayment + extraForSeller;

        makeListingViaMulticall(_tokenId, listingPrice, address(_usdc), 0, address(0));

        uint256 sellerBalanceBefore = IERC20(_usdc).balanceOf(_user);

        purchaseListingViaMulticall(buyer, _tokenId, listingPrice);

        uint256 expectedProtocolFee = (listingPrice * PROTOCOL_FEE_BPS) / 10000;
        uint256 paymentAfterFee = listingPrice - expectedProtocolFee;

        uint256 debtAfter = DynamicCollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(debtAfter, 0, "Seller should still have debt remaining");
        assertEq(debtAfter, maxLoanToken2Only, "Debt should be reduced to maxLoanToken2Only");

        uint256 sellerReceived = IERC20(_usdc).balanceOf(_user) - sellerBalanceBefore;
        assertEq(sellerReceived, paymentAfterFee - expectedRequiredPayment, "Seller should receive excess");

        address buyerWalletPortfolio = _walletFactory.portfolioOf(buyer);
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), buyerWalletPortfolio, "NFT should be in buyer's wallet portfolio");
    }

    // ============ Protocol Fee Tests ============

    function testProtocolFeeIsCalculatedCorrectly() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        uint256 feeRecipientBalanceBefore = IERC20(_usdc).balanceOf(feeRecipient);
        uint256 expectedProtocolFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;

        purchaseListingViaMulticall(buyer, _tokenId, LISTING_PRICE);

        uint256 feeReceived = IERC20(_usdc).balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertEq(feeReceived, expectedProtocolFee, "Fee recipient should receive correct protocol fee");
    }

    function testProtocolFeeIsDeductedFromPayment() public {
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        uint256 sellerBalanceBefore = IERC20(_usdc).balanceOf(_user);
        uint256 feeRecipientBalanceBefore = IERC20(_usdc).balanceOf(feeRecipient);

        purchaseListingViaMulticall(buyer, _tokenId, LISTING_PRICE);

        uint256 expectedProtocolFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        uint256 expectedPaymentToSeller = LISTING_PRICE - expectedProtocolFee;

        uint256 sellerReceived = IERC20(_usdc).balanceOf(_user) - sellerBalanceBefore;
        assertEq(sellerReceived, expectedPaymentToSeller, "Seller should receive payment minus fee");

        uint256 feeReceived = IERC20(_usdc).balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertEq(feeReceived, expectedProtocolFee, "Fee recipient should receive protocol fee");

        assertEq(sellerReceived + feeReceived, LISTING_PRICE, "Total distribution should equal listing price");
    }

    function testProtocolFeeWithZeroFee() public {
        address marketplaceOwner = portfolioMarketplace.owner();
        vm.startPrank(marketplaceOwner);
        portfolioMarketplace.setProtocolFee(0);
        vm.stopPrank();

        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        uint256 sellerBalanceBefore = IERC20(_usdc).balanceOf(_user);
        uint256 feeRecipientBalanceBefore = IERC20(_usdc).balanceOf(feeRecipient);

        purchaseListingViaMulticall(buyer, _tokenId, LISTING_PRICE);

        uint256 feeReceived = IERC20(_usdc).balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertEq(feeReceived, 0, "No fee when protocol fee is 0");

        uint256 sellerReceived = IERC20(_usdc).balanceOf(_user) - sellerBalanceBefore;
        assertEq(sellerReceived, LISTING_PRICE, "Seller should receive full payment");
    }

    // ============ Collateral Enforcement After Sale Tests ============

    /**
     * @notice Seller has 1 token with debt, tries to list below debt amount.
     *         makeListing validates that net proceeds (after protocol fee) cover
     *         the required debt payment, so the listing itself reverts.
     */
    function testRevertSaleOneTokenPriceBelowDebt() public {
        uint256 borrowAmount = 500e6;
        borrowViaMulticall(borrowAmount);

        uint256 totalDebt = DynamicCollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(totalDebt, 0, "Should have debt");

        // List at a price where net proceeds (after 1% fee) are less than debt
        uint256 lowPrice = totalDebt / 2;

        // Listing should revert — price too low to cover debt after fees
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.makeListing.selector,
            _tokenId,
            lowPrice,
            address(_usdc),
            0,
            address(0)
        );
        vm.expectRevert("Price too low to cover debt after fees");
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        // Verify no listing was created
        assertFalse(IMarketplaceFacet(_portfolioAccount).hasSaleAuthorization(_tokenId), "No sale authorization should exist");
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioAccount, "NFT should remain with seller");
    }

    /**
     * @notice Seller lists at a valid price, then borrows more.
     *         When buyer purchases, receiveSaleProceeds enforces collateral requirements
     *         and the sale reverts because the listing price no longer covers the increased debt.
     */
    function testRevertPurchaseAfterBorrowingMoreDebt() public {
        // Borrow a small amount first
        uint256 initialBorrow = 100e6;
        borrowViaMulticall(initialBorrow);

        uint256 debtAfterFirstBorrow = DynamicCollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(debtAfterFirstBorrow, 0, "Should have debt");

        // List at a price that covers the current debt (with room for fees)
        uint256 listingPrice = (debtAfterFirstBorrow * 10100) / 9900;
        makeListingViaMulticall(_tokenId, listingPrice, address(_usdc), 0, address(0));

        // Now borrow more — debt increases beyond what listing price can cover
        (uint256 maxLoanAvailable, ) = DynamicCollateralFacet(_portfolioAccount).getMaxLoan();
        if (maxLoanAvailable > 0) {
            borrowViaMulticall(maxLoanAvailable);
        }

        uint256 totalDebtNow = DynamicCollateralFacet(_portfolioAccount).getTotalDebt();
        uint256 feeBps = portfolioMarketplace.protocolFee();
        uint256 netPayment = listingPrice - (listingPrice * feeBps) / 10000;
        assertGt(totalDebtNow, netPayment, "Debt should exceed net listing proceeds");

        // Fund buyer's wallet
        address buyerWallet = _walletFactory.portfolioOf(buyer);
        deal(address(_usdc), buyerWallet, listingPrice);

        uint256 nonce = portfolioMarketplace.getListing(_tokenId).nonce;

        // Purchase should revert — net proceeds no longer cover debt for single-NFT removal
        vm.startPrank(buyer);
        address[] memory pf = new address[](1);
        pf[0] = address(_walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            _tokenId,
            nonce
        );
        vm.expectRevert();
        _portfolioManager.multicall(cd, pf);
        vm.stopPrank();

        // Verify NFT stayed with seller
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), _portfolioAccount, "NFT should remain with seller");
    }

    function testSaleTwoTokensOneRemainingCoversDebt() public {
        // Add second token to portfolio
        vm.startPrank(_tokenId2Owner);
        IVotingEscrow(_ve).transferFrom(_tokenId2Owner, _portfolioAccount, _tokenId2);
        vm.stopPrank();
        addCollateralViaMulticall(_tokenId2);

        // Borrow a moderate amount — should be covered by remaining token after sale
        uint256 collateral2 = DynamicCollateralFacet(_portfolioAccount).getLockedCollateral(_tokenId2);
        uint256 rewardsRate = _loanConfig.getRewardsRate();
        uint256 multiplier = _loanConfig.getMultiplier();
        uint256 maxLoanToken2Only = (((collateral2 * rewardsRate) / 1000000) * multiplier) / 1e12;

        // Borrow less than what token2 alone can support
        uint256 borrowAmount = maxLoanToken2Only / 2;
        if (borrowAmount == 0) borrowAmount = 1e6;

        borrowViaMulticall(borrowAmount);

        uint256 totalDebt = DynamicCollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(totalDebt, 0, "Should have debt");

        // List token1 at a price well above any required payment
        makeListingViaMulticall(_tokenId, LISTING_PRICE, address(_usdc), 0, address(0));

        address buyerWallet = _walletFactory.portfolioOf(buyer);
        deal(address(_usdc), buyerWallet, LISTING_PRICE);

        uint256 sellerBalanceBefore = IERC20(_usdc).balanceOf(_user);

        // Purchase should succeed — remaining token2 covers remaining debt
        purchaseListingViaMulticall(buyer, _tokenId, LISTING_PRICE);

        // Verify NFT transferred to buyer
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), buyerWallet, "NFT should be in buyer's wallet");

        // Verify seller received proceeds
        uint256 sellerReceived = IERC20(_usdc).balanceOf(_user) - sellerBalanceBefore;
        assertGt(sellerReceived, 0, "Seller should receive remaining proceeds");

        // Verify seller still has token2 as collateral
        uint256 remainingCollateral = DynamicCollateralFacet(_portfolioAccount).getTotalLockedCollateral();
        assertGt(remainingCollateral, 0, "Seller should still have collateral from token2");

        // Verify remaining debt is covered by remaining collateral
        uint256 debtAfter = DynamicCollateralFacet(_portfolioAccount).getTotalDebt();
        (, uint256 maxLoanAfter) = DynamicCollateralFacet(_portfolioAccount).getMaxLoan();
        assertLe(debtAfter, maxLoanAfter, "Remaining debt should be within collateral limits");
    }

    // ============ isListingPurchasable Staleness Tests (DFA-M-004) ============

    /**
     * @notice Verifies that isListingPurchasable reflects vested-but-unsettled
     *         borrower rewards that reduce effective debt, rather than stale stored debt.
     *
     *         Scenario: Seller borrows, rewards are deposited via repayWithRewards,
     *         time passes (rewards vest linearly), and isListingPurchasable should show
     *         the reduced effective debt — not the stale pre-settlement value.
     */
    function testIsListingPurchasableReflectsVestedRewards() public {
        // 1. Borrow against collateral
        uint256 borrowAmount = 500e6;
        borrowViaMulticall(borrowAmount);

        uint256 storedDebt = _dynamicVault.getDebtBalance(_portfolioAccount);
        assertEq(storedDebt, borrowAmount, "Stored debt should match borrow amount");

        // 2. Deposit rewards via repayWithRewards (starts linear vesting)
        uint256 rewardAmount = 200e6;
        deal(address(_usdc), _portfolioAccount, rewardAmount);
        vm.prank(_portfolioAccount);
        IERC20(_usdc).approve(_vault, rewardAmount);
        vm.prank(_portfolioAccount);
        _dynamicVault.repayWithRewards(rewardAmount);

        // Stored debt unchanged (rewards haven't vested yet at this instant)
        uint256 storedDebtAfterReward = _dynamicVault.getDebtBalance(_portfolioAccount);
        assertEq(storedDebtAfterReward, borrowAmount, "Stored debt unchanged immediately after reward deposit");

        // 3. Create listing at a price that covers original debt
        uint256 listingPrice = (borrowAmount * 10200) / 10000; // 2% above debt
        makeListingViaMulticall(_tokenId, listingPrice, address(_usdc), 0, address(0));

        // 4. Warp forward to vest ~50% of rewards (half the remaining epoch duration)
        // ProtocolTimeLibrary: epochNext = timestamp - (timestamp % WEEK) + WEEK
        uint256 WEEK = 7 days;
        uint256 epochEnd = block.timestamp - (block.timestamp % WEEK) + WEEK;
        uint256 halfEpoch = (epochEnd - block.timestamp) / 2;
        vm.warp(block.timestamp + halfEpoch);

        // 5. Stored debt is still the same (no settlement has happened)
        uint256 staleDebt = _dynamicVault.getDebtBalance(_portfolioAccount);
        assertEq(staleDebt, borrowAmount, "Stored debt is stale - no settlement triggered");

        // 6. But getEffectiveDebtBalance should reflect vested rewards
        uint256 effectiveDebt = _dynamicVault.getEffectiveDebtBalance(_portfolioAccount);
        assertLt(effectiveDebt, storedDebt, "Effective debt should be less than stored debt after rewards vest");

        // 7. isListingPurchasable should use the effective (lower) debt
        (bool purchasable, uint256 requiredPayment, uint256 netPayment) =
            IMarketplaceFacet(_portfolioAccount).isListingPurchasable(_tokenId);

        // The required payment is based on effective debt, which is lower
        // than what stale debt would suggest
        uint256 feeBps = portfolioMarketplace.protocolFee();
        uint256 expectedNetPayment = listingPrice - (listingPrice * feeBps) / 10000;
        assertEq(netPayment, expectedNetPayment, "Net payment should match listing price minus fee");

        // requiredPayment should be based on effective debt (not stale stored debt)
        // Since effective debt < stored debt, required payment should be lower
        assertLt(requiredPayment, borrowAmount, "Required payment should reflect vested rewards reducing debt");
        assertTrue(purchasable, "Listing should be purchasable with effective debt accounting");
    }
}
