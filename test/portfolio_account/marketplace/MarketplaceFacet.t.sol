// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Setup} from "../utils/Setup.sol";
import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../src/facets/marketplace/PortfolioMarketplace.sol";
import {IMarketplaceFacet} from "../../../src/interfaces/IMarketplaceFacet.sol";
import {UserMarketplaceModule} from "../../../src/facets/account/marketplace/UserMarketplaceModule.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {CollateralManager} from "../../../src/facets/account/collateral/CollateralManager.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";

contract MarketplaceFacetTest is Test, Setup {
    MarketplaceFacet public marketplaceFacet;
    PortfolioMarketplace public portfolioMarketplace;
    address public buyer;
    address public feeRecipient;
    uint256 public constant LISTING_PRICE = 1000e6; // 1000 USDC
    uint256 public constant PROTOCOL_FEE_BPS = 100; // 1%

    function setUp() public override {
        super.setUp();
        
        buyer = address(0x1234);
        feeRecipient = address(0x5678);
        
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        
        // Deploy PortfolioMarketplace first
        portfolioMarketplace = new PortfolioMarketplace(
            address(_portfolioFactory),
            address(_ve),
            PROTOCOL_FEE_BPS,
            feeRecipient
        );
        
        // Deploy MarketplaceFacet with marketplace address
        marketplaceFacet = new MarketplaceFacet(
            address(_portfolioFactory),
            address(_portfolioAccountConfig),
            address(_ve),
            address(portfolioMarketplace)
        );
        
        // Register MarketplaceFacet in FacetRegistry
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = MarketplaceFacet.makeListing.selector;
        selectors[1] = MarketplaceFacet.cancelListing.selector;
        selectors[2] = MarketplaceFacet.getListing.selector;
        selectors[3] = MarketplaceFacet.processPayment.selector;
        
        _facetRegistry.registerFacet(
            address(marketplaceFacet),
            selectors,
            "MarketplaceFacet"
        );
        
        vm.stopPrank();
        
        // Add collateral to portfolio account
        addCollateralViaMulticall(_tokenId);
        
        // Fund buyer with USDC
        deal(address(_usdc), buyer, LISTING_PRICE * 2);
        
        // Fund vault for potential borrowing
        deal(address(_usdc), _vault, 100000e6);
        
        // Cast _usdc to IERC20 for convenience
        IERC20 usdc = IERC20(_usdc);
    }

    // Helper function to add collateral via PortfolioManager multicall
    function addCollateralViaMulticall(uint256 tokenId) internal {
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            CollateralFacet.addCollateral.selector,
            tokenId
        );
        _portfolioManager.multicall(calldatas, portfolios);
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
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            MarketplaceFacet.makeListing.selector,
            tokenId,
            price,
            paymentToken,
            debtAttached,
            expiresAt,
            allowedBuyer
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
    }

    // Helper function to borrow via PortfolioManager multicall
    function borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            LendingFacet.borrow.selector,
            amount
        );
        _portfolioManager.multicall(calldatas, portfolios);
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
        
        UserMarketplaceModule.Listing memory listing = IMarketplaceFacet(_portfolioAccount).getListing(_tokenId);
        assertEq(listing.price, LISTING_PRICE);
        assertEq(listing.paymentToken, address(_usdc));
        assertEq(listing.debtAttached, 0);
        assertEq(listing.expiresAt, 0);
        assertEq(listing.allowedBuyer, address(0));
    }

    function testCreateListingWithDebtAttached() public {
        uint256 debtAmount = 500e6;
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            debtAmount,
            0,
            address(0)
        );
        
        UserMarketplaceModule.Listing memory listing = IMarketplaceFacet(_portfolioAccount).getListing(_tokenId);
        assertEq(listing.debtAttached, debtAmount);
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
        
        UserMarketplaceModule.Listing memory listing = IMarketplaceFacet(_portfolioAccount).getListing(_tokenId);
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
        
        UserMarketplaceModule.Listing memory listing = IMarketplaceFacet(_portfolioAccount).getListing(_tokenId);
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
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 sellerBalanceBefore = usdc.balanceOf(_user);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        
        // Purchase listing
        vm.startPrank(buyer);
        usdc.approve(address(portfolioMarketplace), LISTING_PRICE);
        portfolioMarketplace.purchaseListing(
            _portfolioAccount,
            _tokenId,
            address(_usdc),
            LISTING_PRICE
        );
        vm.stopPrank();
        
        // Verify NFT transferred to buyer
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), buyer);
        
        // Verify payment distribution (no marketplace fees)
        uint256 sellerReceived = usdc.balanceOf(_user) - sellerBalanceBefore;
        uint256 feeReceived = usdc.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        uint256 buyerSpent = buyerBalanceBefore - usdc.balanceOf(buyer);
        
        assertEq(sellerReceived, LISTING_PRICE, "Seller should receive full price");
        assertEq(feeReceived, 0, "Fee recipient should receive no fee");
        assertEq(buyerSpent, LISTING_PRICE, "Buyer should spend listing price");
        
        // Verify listing is removed
        UserMarketplaceModule.Listing memory listing = IMarketplaceFacet(_portfolioAccount).getListing(_tokenId);
        assertEq(listing.owner, address(0), "Listing should be removed");
    }

    function testPurchaseListingWithDebtPayment() public {
        // Borrow some funds first
        uint256 borrowAmount = 300e6;
        borrowViaMulticall(borrowAmount);
        
        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(totalDebt, 0, "Should have debt");
        
        // Create listing with debt attached
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            totalDebt, // debt attached
            0,
            address(0)
        );
        
        IERC20 usdc = IERC20(_usdc);
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 sellerBalanceBefore = usdc.balanceOf(_user);
        uint256 debtBefore = CollateralFacet(_portfolioAccount).getTotalDebt();
        
        // Purchase listing
        vm.startPrank(buyer);
        usdc.approve(address(portfolioMarketplace), LISTING_PRICE);
        portfolioMarketplace.purchaseListing(
            _portfolioAccount,
            _tokenId,
            address(_usdc),
            LISTING_PRICE
        );
        vm.stopPrank();
        
        // Verify debt is paid
        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertLt(debtAfter, debtBefore, "Debt should be reduced");
        
        // Verify NFT transferred
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), buyer);
        
        // Verify seller receives remaining after debt payment (no marketplace fees)
        uint256 sellerReceived = usdc.balanceOf(_user) - sellerBalanceBefore;
        
        // Seller should receive: price - debt paid
        assertApproxEqRel(
            sellerReceived,
            LISTING_PRICE - debtBefore,
            1e15, // 0.1% tolerance
            "Seller should receive remaining after debt payment"
        );
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
        vm.startPrank(buyer);
        IERC20(_usdc).approve(address(portfolioMarketplace), LISTING_PRICE);
        portfolioMarketplace.purchaseListing(
            _portfolioAccount,
            _tokenId,
            address(_usdc),
            LISTING_PRICE
        );
        vm.stopPrank();
        
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), buyer);
    }

    function testRevertPurchaseListingByRestrictedBuyer() public {
        address otherBuyer = address(0x9999);
        deal(address(_usdc), otherBuyer, LISTING_PRICE);
        
        // Create listing with buyer restriction
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0,
            0,
            buyer
        );
        
        // Purchase by non-allowed buyer should fail
        vm.startPrank(otherBuyer);
        IERC20(_usdc).approve(address(portfolioMarketplace), LISTING_PRICE);
        vm.expectRevert(PortfolioMarketplace.BuyerNotAllowed.selector);
        portfolioMarketplace.purchaseListing(
            _portfolioAccount,
            _tokenId,
            address(_usdc),
            LISTING_PRICE
        );
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
        
        // Fast forward past expiration
        vm.warp(expiresAt + 1);
        
        // Purchase should fail
        vm.startPrank(buyer);
        IERC20(_usdc).approve(address(portfolioMarketplace), LISTING_PRICE);
        vm.expectRevert(PortfolioMarketplace.ListingExpired.selector);
        portfolioMarketplace.purchaseListing(
            _portfolioAccount,
            _tokenId,
            address(_usdc),
            LISTING_PRICE
        );
        vm.stopPrank();
    }

    function testRevertPurchaseWithWrongPrice() public {
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            0,
            0,
            address(0)
        );
        
        // Try to purchase with wrong price
        vm.startPrank(buyer);
        IERC20(_usdc).approve(address(portfolioMarketplace), LISTING_PRICE);
        vm.expectRevert(PortfolioMarketplace.PaymentAmountMismatch.selector);
        portfolioMarketplace.purchaseListing(
            _portfolioAccount,
            _tokenId,
            address(_usdc),
            LISTING_PRICE - 1
        );
        vm.stopPrank();
    }

    function testRevertPurchaseNonExistentListing() public {
        // Try to purchase without creating listing
        vm.startPrank(buyer);
        IERC20(_usdc).approve(address(portfolioMarketplace), LISTING_PRICE);
        vm.expectRevert(PortfolioMarketplace.InvalidListing.selector);
        portfolioMarketplace.purchaseListing(
            _portfolioAccount,
            _tokenId,
            address(_usdc),
            LISTING_PRICE
        );
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
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            MarketplaceFacet.cancelListing.selector,
            _tokenId
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
        
        // Verify listing is removed
        UserMarketplaceModule.Listing memory listing = IMarketplaceFacet(_portfolioAccount).getListing(_tokenId);
        assertEq(listing.owner, address(0), "Listing should be canceled");
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
        
        UserMarketplaceModule.Listing memory listing = portfolioMarketplace.getListing(
            _portfolioAccount,
            _tokenId
        );
        
        assertEq(listing.price, LISTING_PRICE);
        assertEq(listing.paymentToken, address(_usdc));
    }

    function testRevertPurchaseListingWouldCauseUndercollateralization() public {
        // Get a second token ID
        uint256 tokenId2 = 84298;
        
        // Transfer second token to portfolio account
        address token2Owner = IVotingEscrow(_ve).ownerOf(tokenId2);
        vm.startPrank(token2Owner);
        IVotingEscrow(_ve).transferFrom(token2Owner, _portfolioAccount, tokenId2);
        vm.stopPrank();
        
        // Add both tokens as collateral
        addCollateralViaMulticall(_tokenId);
        addCollateralViaMulticall(tokenId2);
        
        // Get max loan with both tokens
        (, uint256 maxLoanIgnoreSupplyWithBoth) = CollateralFacet(_portfolioAccount).getMaxLoan();
        
        // Borrow close to max loan (use 90% to ensure we're close to the limit)
        uint256 borrowAmount = (maxLoanIgnoreSupplyWithBoth * 90) / 100;
        borrowViaMulticall(borrowAmount);
        
        uint256 totalDebt = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertGt(totalDebt, 0, "Should have debt");
        
        // Get collateral amounts
        uint256 collateral1 = CollateralFacet(_portfolioAccount).getLockedCollateral(_tokenId);
        uint256 collateral2 = CollateralFacet(_portfolioAccount).getLockedCollateral(tokenId2);
        
        // Calculate what maxLoanIgnoreSupply would be with only tokenId2
        // Formula: maxLoanIgnoreSupply = (collateral * rewardsRate * multiplier) / (1e12 * 1e6)
        // From Setup: rewardsRate = 10000, multiplier = 100
        uint256 rewardsRate = 10000;
        uint256 multiplier = 100;
        uint256 maxLoanIgnoreSupplyWithToken2Only = (((collateral2 * rewardsRate) / 1000000) * multiplier) / 1e12;
        
        // We want to attach a small amount of debt so that:
        // remainingDebt = totalDebt - debtAttached > maxLoanIgnoreSupplyWithToken2Only
        // This ensures undercollateralization after the sale
        
        // Calculate minimum debt to attach to avoid undercollateralization
        // We want: totalDebt - debtAttached > maxLoanIgnoreSupplyWithToken2Only
        // So: debtAttached < totalDebt - maxLoanIgnoreSupplyWithToken2Only
        // To cause undercollateralization, we attach less than this
        
        uint256 minDebtToAttachToAvoidUndercollateralization = totalDebt > maxLoanIgnoreSupplyWithToken2Only 
            ? totalDebt - maxLoanIgnoreSupplyWithToken2Only 
            : 0;
        
        // Attach a small amount of debt (less than needed to avoid undercollateralization)
        // This ensures remaining debt will exceed maxLoan with only tokenId2
        uint256 debtAttached = minDebtToAttachToAvoidUndercollateralization > 0
            ? minDebtToAttachToAvoidUndercollateralization / 2  // Attach half of what's needed
            : totalDebt / 10; // If already undercollateralized, attach small amount
        
        // Verify the scenario: after sale, remaining debt should exceed maxLoan with tokenId2 only
        uint256 remainingDebtAfterSale = totalDebt - debtAttached;
        require(
            remainingDebtAfterSale > maxLoanIgnoreSupplyWithToken2Only,
            "Test setup: This scenario would not cause undercollateralization"
        );
        
        makeListingViaMulticall(
            _tokenId,
            LISTING_PRICE,
            address(_usdc),
            debtAttached,
            0,
            address(0)
        );
        
        // Try to purchase - should revert because it would cause undercollateralization
        vm.startPrank(buyer);
        IERC20(_usdc).approve(address(portfolioMarketplace), LISTING_PRICE);
        
        // The purchase should revert when enforceCollateralRequirements is called
        // This happens at the end of processPayment after removing collateral
        // It will revert with UndercollateralizedDebt error
        // Since we can't predict the exact debt amount, we use expectRevert() to match any revert
        vm.expectRevert();
        
        portfolioMarketplace.purchaseListing(
            _portfolioAccount,
            _tokenId,
            address(_usdc),
            LISTING_PRICE
        );
        vm.stopPrank();
        
        // Now update the listing to pay down enough debt to avoid undercollateralization
        // Cancel the current listing
        vm.startPrank(_user);
        address[] memory portfolios = new address[](1);
        portfolios[0] = _portfolioAccount;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            MarketplaceFacet.cancelListing.selector,
            _tokenId
        );
        _portfolioManager.multicall(calldatas, portfolios);
        vm.stopPrank();
        
        // Calculate debtAttached that would avoid undercollateralization
        // We need: totalDebt - debtAttached <= maxLoanIgnoreSupplyWithToken2Only
        // So: debtAttached >= totalDebt - maxLoanIgnoreSupplyWithToken2Only
        // To be safe, we'll pay down enough debt to leave a comfortable margin
        // Pay down enough to leave remaining debt well below maxLoan with tokenId2 only
        uint256 targetRemainingDebt = (maxLoanIgnoreSupplyWithToken2Only * 80) / 100; // Leave 20% margin
        uint256 sufficientDebtAttached = totalDebt > targetRemainingDebt
            ? totalDebt - targetRemainingDebt
            : totalDebt; // If already safe, pay all debt
        
        // Ensure we don't exceed total debt
        if (sufficientDebtAttached > totalDebt) {
            sufficientDebtAttached = totalDebt;
        }
        
        // Use a higher listing price to ensure it covers the debt payment
        // The listing price should be at least the debt amount plus some extra for the seller
        uint256 sufficientListingPrice = sufficientDebtAttached > LISTING_PRICE
            ? sufficientDebtAttached + 100e6  // Add 100 USDC buffer
            : LISTING_PRICE;
        
        // Ensure buyer has enough USDC for the purchase
        uint256 buyerBalance = IERC20(_usdc).balanceOf(buyer);
        if (buyerBalance < sufficientListingPrice) {
            deal(address(_usdc), buyer, sufficientListingPrice);
        }
        
        // Create new listing with sufficient debt attached
        makeListingViaMulticall(
            _tokenId,
            sufficientListingPrice,
            address(_usdc),
            sufficientDebtAttached,
            0,
            address(0)
        );
        
        // Purchase should now succeed
        vm.startPrank(buyer);
        IERC20(_usdc).approve(address(portfolioMarketplace), sufficientListingPrice);
        
        portfolioMarketplace.purchaseListing(
            _portfolioAccount,
            _tokenId,
            address(_usdc),
            sufficientListingPrice
        );
        vm.stopPrank();
        
        // Verify NFT was transferred
        assertEq(IVotingEscrow(_ve).ownerOf(_tokenId), buyer, "NFT should be transferred to buyer");
        
        // Verify debt was reduced
        uint256 debtAfter = CollateralFacet(_portfolioAccount).getTotalDebt();
        assertLt(debtAfter, totalDebt, "Debt should be reduced");
        
        // Verify listing is removed
        UserMarketplaceModule.Listing memory listing = IMarketplaceFacet(_portfolioAccount).getListing(_tokenId);
        assertEq(listing.owner, address(0), "Listing should be removed");

        assertGt(debtAfter, 0, "Debt should be greater than 0");
    }
}

