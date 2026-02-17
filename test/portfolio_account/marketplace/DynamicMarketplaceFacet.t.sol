// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {DynamicMarketplaceFacet} from "../../../src/facets/account/marketplace/DynamicMarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../src/facets/marketplace/PortfolioMarketplace.sol";
import {IMarketplaceFacet} from "../../../src/interfaces/IMarketplaceFacet.sol";
import {UserMarketplaceModule} from "../../../src/facets/account/marketplace/UserMarketplaceModule.sol";
import {DynamicCollateralFacet} from "../../../src/facets/account/collateral/DynamicCollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {DynamicLendingFacet} from "../../../src/facets/account/lending/DynamicLendingFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {DynamicVotingEscrowFacet} from "../../../src/facets/account/votingEscrow/DynamicVotingEscrowFacet.sol";
import {ERC721ReceiverFacet} from "../../../src/facets/ERC721ReceiverFacet.sol";
import {FortyAcresMarketplaceFacet} from "../../../src/facets/account/marketplace/FortyAcresMarketplaceFacet.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {DeployPortfolioAccountConfig} from "../../../script/portfolio_account/DeployPortfolioAccountConfig.s.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DynamicMarketplaceFacetTest
 * @dev Marketplace tests for diamonds using DynamicFeesVault + DynamicMarketplaceFacet.
 *      Replicates MarketplaceFacet.t.sol tests to ensure both paths work the same way.
 *      Key differences from the standard marketplace tests:
 *      - Debt is tracked in DynamicFeesVault, not locally
 *      - No unpaid fees (getUnpaidFees() always returns 0)
 *      - P2P debt transfer uses vault.transferDebt() atomically
 */
contract DynamicMarketplaceFacetTest is Test {
    // Base chain addresses
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address public constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address public constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;

    // Test actors
    address public user = address(0x40ac2e);
    address public buyer = address(0x1234);
    address public vaultDepositor = address(0xbbbbb);
    address public feeRecipient = address(0x5678);

    // Core contracts
    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioAccountConfig public portfolioAccountConfig;
    LoanConfig public loanConfig;

    // Portfolio accounts
    address public portfolioAccount;

    // DynamicFeesVault
    DynamicFeesVault public vault;

    // Marketplace
    PortfolioMarketplace public portfolioMarketplace;

    // External contracts
    IVotingEscrow public veAERO = IVotingEscrow(VOTING_ESCROW);
    IERC20 public aero = IERC20(AERO);
    IERC20 public usdc = IERC20(USDC);

    // Test constants
    uint256 public constant LOCK_AMOUNT = 1000 ether;
    uint256 public constant VAULT_INITIAL_DEPOSIT = 100_000e6;
    uint256 public constant LISTING_PRICE = 1000e6;
    uint256 public constant PROTOCOL_FEE_BPS = 100; // 1%

    // Token ID (created in setUp via createLock)
    uint256 public tokenId;

    function setUp() public {
        // Fork Base network
        uint256 fork = vm.createFork(vm.envString("BASE_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(38869188);
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        vm.startPrank(DEPLOYER);

        // Deploy core contracts
        portfolioManager = new PortfolioManager(DEPLOYER);
        (portfolioFactory, facetRegistry) = portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("dynamic-marketplace-test")))
        );

        // Deploy configs
        DeployPortfolioAccountConfig configDeployer = new DeployPortfolioAccountConfig();
        (portfolioAccountConfig,, loanConfig,) = configDeployer.deploy();

        // Deploy DynamicFeesVault
        DynamicFeesVault vaultImpl = new DynamicFeesVault();
        bytes memory initData = abi.encodeWithSelector(
            DynamicFeesVault.initialize.selector,
            USDC,
            "Test Dynamic USDC Vault",
            "T-DV-USDC",
            address(portfolioFactory)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = DynamicFeesVault(address(vaultProxy));
        vault.transferOwnership(DEPLOYER);

        // Configure
        portfolioAccountConfig.setLoanContract(address(vault));
        loanConfig.setRewardsRate(10000); // 1%
        loanConfig.setMultiplier(100);
        portfolioAccountConfig.setLoanConfig(address(loanConfig));
        portfolioManager.setAuthorizedCaller(address(0xaaaaa), true);

        // Deploy PortfolioMarketplace
        portfolioMarketplace = new PortfolioMarketplace(
            address(portfolioFactory),
            VOTING_ESCROW,
            PROTOCOL_FEE_BPS,
            feeRecipient
        );

        // Deploy all facets
        _deployFacets();

        vm.stopPrank();

        // Fund vault with USDC via deposit
        deal(USDC, vaultDepositor, VAULT_INITIAL_DEPOSIT);
        vm.startPrank(vaultDepositor);
        usdc.approve(address(vault), VAULT_INITIAL_DEPOSIT);
        vault.deposit(VAULT_INITIAL_DEPOSIT, vaultDepositor);
        vm.stopPrank();

        // Create user's portfolio account
        portfolioAccount = portfolioFactory.createAccount(user);

        // Fund user with AERO for lock creation
        deal(AERO, user, LOCK_AMOUNT * 10);
        deal(USDC, user, 1_000_000e6);

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // Create veAERO lock (also adds collateral)
        tokenId = _createLockForUser();

        // Create buyer's portfolio account
        vm.startPrank(buyer);
        portfolioFactory.createAccount(buyer);
        vm.stopPrank();

        // Fund buyer with USDC
        deal(USDC, buyer, LISTING_PRICE * 10);

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    function _deployFacets() internal {
        // DynamicCollateralFacet
        DynamicCollateralFacet collateralFacet = new DynamicCollateralFacet(
            address(portfolioFactory),
            address(portfolioAccountConfig),
            VOTING_ESCROW
        );
        bytes4[] memory collateralSelectors = new bytes4[](11);
        collateralSelectors[0] = BaseCollateralFacet.addCollateral.selector;
        collateralSelectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        collateralSelectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        collateralSelectors[3] = BaseCollateralFacet.getUnpaidFees.selector;
        collateralSelectors[4] = BaseCollateralFacet.getMaxLoan.selector;
        collateralSelectors[5] = BaseCollateralFacet.getOriginTimestamp.selector;
        collateralSelectors[6] = BaseCollateralFacet.removeCollateral.selector;
        collateralSelectors[7] = BaseCollateralFacet.getCollateralToken.selector;
        collateralSelectors[8] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        collateralSelectors[9] = BaseCollateralFacet.getLockedCollateral.selector;
        collateralSelectors[10] = BaseCollateralFacet.removeCollateralTo.selector;
        facetRegistry.registerFacet(address(collateralFacet), collateralSelectors, "DynamicCollateralFacet");

        // DynamicVotingEscrowFacet
        DynamicVotingEscrowFacet votingEscrowFacet = new DynamicVotingEscrowFacet(
            address(portfolioFactory),
            address(portfolioAccountConfig),
            VOTING_ESCROW,
            VOTER
        );
        bytes4[] memory votingEscrowSelectors = new bytes4[](3);
        votingEscrowSelectors[0] = DynamicVotingEscrowFacet.increaseLock.selector;
        votingEscrowSelectors[1] = DynamicVotingEscrowFacet.createLock.selector;
        votingEscrowSelectors[2] = DynamicVotingEscrowFacet.merge.selector;
        facetRegistry.registerFacet(address(votingEscrowFacet), votingEscrowSelectors, "DynamicVotingEscrowFacet");

        // ERC721ReceiverFacet
        ERC721ReceiverFacet erc721ReceiverFacet = new ERC721ReceiverFacet();
        bytes4[] memory erc721ReceiverSelectors = new bytes4[](1);
        erc721ReceiverSelectors[0] = ERC721ReceiverFacet.onERC721Received.selector;
        facetRegistry.registerFacet(address(erc721ReceiverFacet), erc721ReceiverSelectors, "ERC721ReceiverFacet");

        // DynamicLendingFacet
        DynamicLendingFacet lendingFacet = new DynamicLendingFacet(
            address(portfolioFactory),
            address(portfolioAccountConfig),
            USDC
        );
        bytes4[] memory lendingSelectors = new bytes4[](5);
        lendingSelectors[0] = BaseLendingFacet.borrow.selector;
        lendingSelectors[1] = BaseLendingFacet.borrowTo.selector;
        lendingSelectors[2] = BaseLendingFacet.pay.selector;
        lendingSelectors[3] = BaseLendingFacet.setTopUp.selector;
        lendingSelectors[4] = BaseLendingFacet.topUp.selector;
        facetRegistry.registerFacet(address(lendingFacet), lendingSelectors, "DynamicLendingFacet");

        // DynamicMarketplaceFacet
        DynamicMarketplaceFacet marketplaceFacet = new DynamicMarketplaceFacet(
            address(portfolioFactory),
            address(portfolioAccountConfig),
            VOTING_ESCROW,
            address(portfolioMarketplace)
        );
        bytes4[] memory marketplaceSelectors = new bytes4[](11);
        marketplaceSelectors[0] = BaseMarketplaceFacet.processPayment.selector;
        marketplaceSelectors[1] = BaseMarketplaceFacet.finalizePurchase.selector;
        marketplaceSelectors[2] = BaseMarketplaceFacet.buyMarketplaceListing.selector;
        marketplaceSelectors[3] = BaseMarketplaceFacet.getListing.selector;
        marketplaceSelectors[4] = BaseMarketplaceFacet.transferDebtToBuyer.selector;
        marketplaceSelectors[5] = BaseMarketplaceFacet.makeListing.selector;
        marketplaceSelectors[6] = BaseMarketplaceFacet.cancelListing.selector;
        marketplaceSelectors[7] = BaseMarketplaceFacet.marketplace.selector;
        marketplaceSelectors[8] = BaseMarketplaceFacet.isListingValid.selector;
        marketplaceSelectors[9] = BaseMarketplaceFacet.getListingNonce.selector;
        marketplaceSelectors[10] = BaseMarketplaceFacet.buyMarketplaceListings.selector;
        facetRegistry.registerFacet(address(marketplaceFacet), marketplaceSelectors, "DynamicMarketplaceFacet");

        // FortyAcresMarketplaceFacet (for buyer multicall tests)
        FortyAcresMarketplaceFacet fortyAcresFacet = new FortyAcresMarketplaceFacet(
            address(portfolioFactory),
            address(portfolioAccountConfig),
            VOTING_ESCROW,
            address(portfolioMarketplace)
        );
        bytes4[] memory fortyAcresSelectors = new bytes4[](1);
        fortyAcresSelectors[0] = FortyAcresMarketplaceFacet.buyFortyAcresListing.selector;
        facetRegistry.registerFacet(address(fortyAcresFacet), fortyAcresSelectors, "FortyAcresMarketplaceFacet");
    }

    // ============ Helper Functions ============

    function _createLockForUser() internal returns (uint256 _tokenId) {
        vm.startPrank(user);

        aero.approve(portfolioAccount, LOCK_AMOUNT);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(DynamicVotingEscrowFacet.createLock.selector, LOCK_AMOUNT);

        bytes[] memory results = portfolioManager.multicall(calldatas, factories);
        _tokenId = abi.decode(results[0], (uint256));

        vm.stopPrank();
    }

    function addCollateralViaMulticall(uint256 _tokenId) internal {
        vm.startPrank(user);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, _tokenId);
        portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function removeCollateralViaMulticall(uint256 _tokenId) internal {
        vm.startPrank(user);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, _tokenId);
        portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function makeListingViaMulticall(
        uint256 _tokenId,
        uint256 price,
        address paymentToken,
        uint256 debtAttached,
        uint256 expiresAt,
        address allowedBuyer
    ) internal {
        vm.startPrank(user);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.makeListing.selector,
            _tokenId,
            price,
            paymentToken,
            debtAttached,
            expiresAt,
            allowedBuyer
        );
        portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function borrowViaMulticall(uint256 amount) internal {
        vm.startPrank(user);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseLendingFacet.borrow.selector, amount);
        portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    // ============ Listing CRUD Tests ============

    function testCreateListing() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, address(0));

        UserMarketplaceModule.Listing memory listing = IMarketplaceFacet(portfolioAccount).getListing(tokenId);
        assertEq(listing.price, LISTING_PRICE);
        assertEq(listing.paymentToken, USDC);
        assertEq(listing.debtAttached, 0);
        assertEq(listing.expiresAt, 0);
        assertEq(listing.allowedBuyer, address(0));
    }

    function testCreateListingWithDebtAttached() public {
        uint256 debtAmount = 500e6;
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, debtAmount, 0, address(0));

        UserMarketplaceModule.Listing memory listing = IMarketplaceFacet(portfolioAccount).getListing(tokenId);
        assertEq(listing.debtAttached, debtAmount);
    }

    function testCreateListingWithExpiration() public {
        uint256 expiresAt = block.timestamp + 7 days;
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, expiresAt, address(0));

        UserMarketplaceModule.Listing memory listing = IMarketplaceFacet(portfolioAccount).getListing(tokenId);
        assertEq(listing.expiresAt, expiresAt);
    }

    function testCreateListingWithAllowedBuyer() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, buyer);

        UserMarketplaceModule.Listing memory listing = IMarketplaceFacet(portfolioAccount).getListing(tokenId);
        assertEq(listing.allowedBuyer, buyer);
    }

    function testCancelListing() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, address(0));

        vm.startPrank(user);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseMarketplaceFacet.cancelListing.selector, tokenId);
        portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        UserMarketplaceModule.Listing memory listing = IMarketplaceFacet(portfolioAccount).getListing(tokenId);
        assertEq(listing.owner, address(0), "Listing should be canceled");
    }

    function testRevertCancelListingWhenNoListingExists() public {
        vm.startPrank(user);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseMarketplaceFacet.cancelListing.selector, tokenId);
        vm.expectRevert();
        portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function testRevertCreateListingWhenListingAlreadyExists() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, address(0));

        vm.startPrank(user);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.makeListing.selector, tokenId, LISTING_PRICE * 2, USDC, 0, 0, address(0)
        );
        vm.expectRevert("Listing already exists");
        portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function testGetListing() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, address(0));

        UserMarketplaceModule.Listing memory listing = portfolioMarketplace.getListing(portfolioAccount, tokenId);
        assertEq(listing.price, LISTING_PRICE);
        assertEq(listing.paymentToken, USDC);
    }

    function testCannotRemoveCollateralWhenListed() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, address(0));

        vm.expectRevert(abi.encodeWithSelector(BaseCollateralFacet.ListingActive.selector, tokenId));
        removeCollateralViaMulticall(tokenId);
    }

    // ============ P2P Purchase Tests (via PortfolioMarketplace.purchaseListing) ============

    function testPurchaseListing() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, address(0));

        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        uint256 sellerBalanceBefore = usdc.balanceOf(user);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        vm.startPrank(buyer);
        usdc.approve(address(portfolioMarketplace), LISTING_PRICE);
        portfolioMarketplace.purchaseListing(portfolioAccount, tokenId, USDC, LISTING_PRICE);
        vm.stopPrank();

        address buyerPortfolio = portfolioFactory.portfolioOf(buyer);

        // Verify NFT transferred to buyer's portfolio
        assertEq(veAERO.ownerOf(tokenId), buyerPortfolio, "NFT should be in buyer's portfolio");

        // Verify payment distribution
        uint256 expectedProtocolFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        uint256 paymentAfterFee = LISTING_PRICE - expectedProtocolFee;

        uint256 feeReceived = usdc.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertEq(feeReceived, expectedProtocolFee, "Fee recipient should receive protocol fee");

        uint256 sellerReceived = usdc.balanceOf(user) - sellerBalanceBefore;
        assertEq(sellerReceived, paymentAfterFee, "Seller should receive payment minus protocol fee");

        uint256 buyerSpent = buyerBalanceBefore - usdc.balanceOf(buyer);
        assertEq(buyerSpent, LISTING_PRICE, "Buyer should spend listing price");

        // Verify listing is removed
        UserMarketplaceModule.Listing memory listing = IMarketplaceFacet(portfolioAccount).getListing(tokenId);
        assertEq(listing.owner, address(0), "Listing should be removed");
    }

    function testPurchaseListingWithDebtPayment() public {
        // Borrow funds to create debt in vault
        uint256 borrowAmount = 300e6;
        borrowViaMulticall(borrowAmount);

        uint256 totalDebt = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertGt(totalDebt, 0, "Should have debt");

        // Create listing with debt attached (debt will be transferred via vault.transferDebt)
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, totalDebt, 0, address(0));

        uint256 sellerBalanceBefore = usdc.balanceOf(user);
        uint256 debtBefore = DynamicCollateralFacet(portfolioAccount).getTotalDebt();

        vm.startPrank(buyer);
        usdc.approve(address(portfolioMarketplace), LISTING_PRICE);
        portfolioMarketplace.purchaseListing(portfolioAccount, tokenId, USDC, LISTING_PRICE);
        vm.stopPrank();

        // Verify debt is transferred atomically (not paid down) via vault.transferDebt
        uint256 debtAfter = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debtAfter, 0, "Seller should have no debt after transfer");

        // Verify vault tracks debt on buyer's portfolio
        address buyerPortfolio = portfolioFactory.portfolioOf(buyer);
        uint256 buyerDebt = vault.getDebtBalance(buyerPortfolio);
        assertEq(buyerDebt, debtBefore, "Buyer should have received seller's debt in vault");

        // Verify NFT transferred
        assertEq(veAERO.ownerOf(tokenId), buyerPortfolio, "NFT should be in buyer's portfolio");

        // Verify seller receives full listing price minus fee (debt is transferred, not deducted)
        uint256 sellerReceived = usdc.balanceOf(user) - sellerBalanceBefore;
        uint256 expectedProtocolFees = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        assertApproxEqRel(sellerReceived, LISTING_PRICE - expectedProtocolFees, 1e15, "Seller should receive listing price minus fee");
    }

    function testPurchaseListingTransfersDebtNoUnpaidFees() public {
        // DynamicFeesVault has no unpaid fees — verify debt transfer works without them
        address buyerPortfolio = portfolioFactory.portfolioOf(buyer);
        require(buyerPortfolio != address(0), "Buyer portfolio should exist");

        uint256 borrowAmount = 500e6;
        borrowViaMulticall(borrowAmount);

        uint256 sellerDebtBefore = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        uint256 sellerUnpaidFeesBefore = DynamicCollateralFacet(portfolioAccount).getUnpaidFees();

        assertGt(sellerDebtBefore, 0, "Seller should have debt");
        assertEq(sellerUnpaidFeesBefore, 0, "DynamicFeesVault should have no unpaid fees");

        // Create listing with all debt attached
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, sellerDebtBefore, 0, address(0));

        uint256 buyerDebtBefore = DynamicCollateralFacet(buyerPortfolio).getTotalDebt();

        vm.startPrank(buyer);
        usdc.approve(address(portfolioMarketplace), LISTING_PRICE);
        portfolioMarketplace.purchaseListing(portfolioAccount, tokenId, USDC, LISTING_PRICE);
        vm.stopPrank();

        // Verify NFT transferred
        assertEq(veAERO.ownerOf(tokenId), buyerPortfolio, "NFT should be in buyer's portfolio");

        // Verify seller's debt was transferred away
        uint256 sellerDebtAfter = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        uint256 sellerUnpaidFeesAfter = DynamicCollateralFacet(portfolioAccount).getUnpaidFees();
        assertEq(sellerDebtAfter, 0, "Seller should have no debt after transfer");
        assertEq(sellerUnpaidFeesAfter, 0, "Seller should have no unpaid fees");

        // Verify buyer received debt via vault
        uint256 buyerDebtAfter = DynamicCollateralFacet(buyerPortfolio).getTotalDebt();
        assertEq(buyerDebtAfter, buyerDebtBefore + sellerDebtBefore, "Buyer should have received seller's debt");

        // Verify buyer has NFT as collateral
        uint256 buyerCollateral = DynamicCollateralFacet(buyerPortfolio).getLockedCollateral(tokenId);
        assertGt(buyerCollateral, 0, "Buyer should have NFT as collateral");
    }

    function testPurchaseListingTransfersPartialDebt() public {
        address buyerPortfolio = portfolioFactory.portfolioOf(buyer);

        // Need second NFT so seller has collateral after selling one
        uint256 tokenId2 = 84298;
        address token2Owner = veAERO.ownerOf(tokenId2);
        vm.startPrank(token2Owner);
        veAERO.transferFrom(token2Owner, portfolioAccount, tokenId2);
        vm.stopPrank();
        addCollateralViaMulticall(tokenId2);

        // Borrow
        uint256 borrowAmount = 500e6;
        borrowViaMulticall(borrowAmount);

        uint256 sellerTotalDebt = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertGt(sellerTotalDebt, 0, "Seller should have debt");

        // Attach half the debt
        uint256 debtAttached = sellerTotalDebt / 2;

        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, debtAttached, 0, address(0));

        uint256 buyerDebtBefore = DynamicCollateralFacet(buyerPortfolio).getTotalDebt();

        vm.startPrank(buyer);
        usdc.approve(address(portfolioMarketplace), LISTING_PRICE);
        portfolioMarketplace.purchaseListing(portfolioAccount, tokenId, USDC, LISTING_PRICE);
        vm.stopPrank();

        // Verify seller's debt reduced by transferred amount
        uint256 sellerDebtAfter = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(sellerDebtAfter, sellerTotalDebt - debtAttached, "Seller debt should be reduced by transferred amount");

        // Verify buyer received transferred debt
        uint256 buyerDebtAfter = DynamicCollateralFacet(buyerPortfolio).getTotalDebt();
        assertEq(buyerDebtAfter, buyerDebtBefore + debtAttached, "Buyer should have received transferred debt");

        // Verify NFT transferred
        assertEq(veAERO.ownerOf(tokenId), buyerPortfolio, "NFT should be transferred");
    }

    function testPurchaseListingWithRestrictedBuyer() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, buyer);

        vm.startPrank(buyer);
        usdc.approve(address(portfolioMarketplace), LISTING_PRICE);
        portfolioMarketplace.purchaseListing(portfolioAccount, tokenId, USDC, LISTING_PRICE);
        vm.stopPrank();

        address buyerPortfolio = portfolioFactory.portfolioOf(buyer);
        assertEq(veAERO.ownerOf(tokenId), buyerPortfolio, "NFT should be in buyer's portfolio");
    }

    function testRevertPurchaseListingByRestrictedBuyer() public {
        address otherBuyer = address(0x9999);
        deal(USDC, otherBuyer, LISTING_PRICE);

        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, buyer);

        vm.startPrank(otherBuyer);
        usdc.approve(address(portfolioMarketplace), LISTING_PRICE);
        vm.expectRevert(PortfolioMarketplace.BuyerNotAllowed.selector);
        portfolioMarketplace.purchaseListing(portfolioAccount, tokenId, USDC, LISTING_PRICE);
        vm.stopPrank();
    }

    function testRevertPurchaseExpiredListing() public {
        uint256 expiresAt = block.timestamp + 1 days;
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, expiresAt, address(0));

        vm.warp(expiresAt + 1);

        vm.startPrank(buyer);
        usdc.approve(address(portfolioMarketplace), LISTING_PRICE);
        vm.expectRevert(PortfolioMarketplace.ListingExpired.selector);
        portfolioMarketplace.purchaseListing(portfolioAccount, tokenId, USDC, LISTING_PRICE);
        vm.stopPrank();
    }

    function testRevertPurchaseWithWrongPrice() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, address(0));

        vm.startPrank(buyer);
        usdc.approve(address(portfolioMarketplace), LISTING_PRICE);
        vm.expectRevert(PortfolioMarketplace.PaymentAmountMismatch.selector);
        portfolioMarketplace.purchaseListing(portfolioAccount, tokenId, USDC, LISTING_PRICE - 1);
        vm.stopPrank();
    }

    function testRevertPurchaseNonExistentListing() public {
        vm.startPrank(buyer);
        usdc.approve(address(portfolioMarketplace), LISTING_PRICE);
        vm.expectRevert(PortfolioMarketplace.InvalidListing.selector);
        portfolioMarketplace.purchaseListing(portfolioAccount, tokenId, USDC, LISTING_PRICE);
        vm.stopPrank();
    }

    // ============ buyMarketplaceListing Tests (External Buyer) ============

    function testBuyMarketplaceListingWithoutDebt() public {
        address nonPortfolioBuyer = address(0x9999);
        deal(USDC, nonPortfolioBuyer, LISTING_PRICE);

        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, address(0));

        uint256 buyerBalanceBefore = usdc.balanceOf(nonPortfolioBuyer);

        vm.startPrank(nonPortfolioBuyer);
        usdc.approve(portfolioAccount, LISTING_PRICE);
        BaseMarketplaceFacet(portfolioAccount).buyMarketplaceListing(tokenId, nonPortfolioBuyer);
        vm.stopPrank();

        // NFT transferred to buyer (not portfolio)
        assertEq(veAERO.ownerOf(tokenId), nonPortfolioBuyer, "NFT should be transferred to buyer");
        assertFalse(portfolioFactory.isPortfolio(nonPortfolioBuyer), "Buyer should not have portfolio account");

        // Buyer paid full price
        uint256 buyerBalanceAfter = usdc.balanceOf(nonPortfolioBuyer);
        assertEq(buyerBalanceBefore - buyerBalanceAfter, LISTING_PRICE, "Buyer should pay full price");

        // Listing removed
        UserMarketplaceModule.Listing memory listing = IMarketplaceFacet(portfolioAccount).getListing(tokenId);
        assertEq(listing.owner, address(0), "Listing should be removed");

        // Collateral removed from seller
        uint256 collateral = DynamicCollateralFacet(portfolioAccount).getLockedCollateral(tokenId);
        assertEq(collateral, 0, "Collateral should be removed");
    }

    function testBuyMarketplaceListingWithDebt() public {
        // Borrow to create debt in vault
        uint256 borrowAmount = 300e6;
        borrowViaMulticall(borrowAmount);

        uint256 totalDebt = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertGt(totalDebt, 0, "Should have debt");

        // List without debt attached — debt paid from listing price
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, address(0));

        address nonPortfolioBuyer = address(0x9999);
        deal(USDC, nonPortfolioBuyer, LISTING_PRICE);

        uint256 buyerBalanceBefore = usdc.balanceOf(nonPortfolioBuyer);
        uint256 sellerBalanceBefore = usdc.balanceOf(user);
        uint256 debtBefore = DynamicCollateralFacet(portfolioAccount).getTotalDebt();

        vm.startPrank(nonPortfolioBuyer);
        usdc.approve(portfolioAccount, LISTING_PRICE);
        BaseMarketplaceFacet(portfolioAccount).buyMarketplaceListing(tokenId, nonPortfolioBuyer);
        vm.stopPrank();

        assertEq(veAERO.ownerOf(tokenId), nonPortfolioBuyer, "NFT should be transferred");

        // Debt reduced via vault's payFromPortfolio
        uint256 debtAfter = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertLt(debtAfter, debtBefore, "Debt should be reduced");

        // Buyer paid full listing price
        uint256 buyerBalanceAfter = usdc.balanceOf(nonPortfolioBuyer);
        assertEq(buyerBalanceAfter, buyerBalanceBefore - LISTING_PRICE, "Buyer should pay full price");

        // Seller receives excess after fee and debt payment
        uint256 sellerBalanceAfter = usdc.balanceOf(user);
        uint256 expectedProtocolFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        uint256 paymentAfterFee = LISTING_PRICE - expectedProtocolFee;
        if (paymentAfterFee > debtBefore) {
            uint256 excess = paymentAfterFee - debtBefore;
            assertEq(sellerBalanceAfter, sellerBalanceBefore + excess, "Seller should receive excess");
        }
    }

    function testBuyMarketplaceListingWithDebtAttached() public {
        uint256 borrowAmount = 500e6;
        borrowViaMulticall(borrowAmount);

        uint256 totalDebt = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertGt(totalDebt, 0, "Should have debt");

        uint256 debtAttached = totalDebt;
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, debtAttached, 0, address(0));

        address nonPortfolioBuyer = address(0x9999);
        deal(USDC, nonPortfolioBuyer, LISTING_PRICE + debtAttached);

        uint256 buyerBalanceBefore = usdc.balanceOf(nonPortfolioBuyer);

        vm.startPrank(nonPortfolioBuyer);
        usdc.approve(portfolioAccount, LISTING_PRICE + debtAttached);
        BaseMarketplaceFacet(portfolioAccount).buyMarketplaceListing(tokenId, nonPortfolioBuyer);
        vm.stopPrank();

        assertEq(veAERO.ownerOf(tokenId), nonPortfolioBuyer, "NFT should be transferred");

        // Debt should be cleared (paid via decreaseTotalDebt → vault.payFromPortfolio)
        uint256 debtAfter = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debtAfter, 0, "Debt should be cleared");

        // Buyer paid listing price + debt attached
        uint256 buyerBalanceAfter = usdc.balanceOf(nonPortfolioBuyer);
        uint256 totalPaid = buyerBalanceBefore - buyerBalanceAfter;
        assertGe(totalPaid, LISTING_PRICE, "Buyer should pay at least listing price");
        assertLe(totalPaid, LISTING_PRICE + debtAttached, "Buyer should not pay more than price + debt");
    }

    function testBuyMarketplaceListingWithDebtAttachedCorrectPayment() public {
        // Test exact payment flow: seller has 100 USDC debt, listing price 150, debt attached 100
        uint256 initialDebt = 100e6;
        borrowViaMulticall(initialDebt);

        uint256 totalDebt = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(totalDebt, initialDebt, "Should have 100 USDC debt");

        uint256 listingPrice = 150e6;
        uint256 debtAttached = 100e6;
        makeListingViaMulticall(tokenId, listingPrice, USDC, debtAttached, 0, address(0));

        address nonPortfolioBuyer = address(0x9999);
        deal(USDC, nonPortfolioBuyer, listingPrice + debtAttached);

        uint256 sellerBalanceBefore = usdc.balanceOf(user);
        uint256 buyerBalanceBefore = usdc.balanceOf(nonPortfolioBuyer);

        vm.startPrank(nonPortfolioBuyer);
        usdc.approve(portfolioAccount, listingPrice + debtAttached);
        BaseMarketplaceFacet(portfolioAccount).buyMarketplaceListing(tokenId, nonPortfolioBuyer);
        vm.stopPrank();

        assertEq(veAERO.ownerOf(tokenId), nonPortfolioBuyer, "NFT should be transferred");

        // Debt cleared
        uint256 debtAfter = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debtAfter, 0, "Debt should be cleared");

        // Protocol fee from listing price
        uint256 expectedProtocolFee = (listingPrice * PROTOCOL_FEE_BPS) / 10000;
        uint256 expectedSellerPayment = listingPrice - expectedProtocolFee;

        // Seller received listing price minus fee
        uint256 sellerBalanceAfter = usdc.balanceOf(user);
        uint256 sellerReceived = sellerBalanceAfter - sellerBalanceBefore;
        assertEq(sellerReceived, expectedSellerPayment, "Seller should receive listing price minus protocol fee");

        // Buyer paid exactly listing price + debt attached
        uint256 buyerBalanceAfter = usdc.balanceOf(nonPortfolioBuyer);
        uint256 buyerPaid = buyerBalanceBefore - buyerBalanceAfter;
        assertEq(buyerPaid, listingPrice + debtAttached, "Buyer should pay exactly 250 USDC (150 + 100)");

        // Fee recipient got fee
        uint256 feeRecipientBalance = usdc.balanceOf(feeRecipient);
        assertGe(feeRecipientBalance, expectedProtocolFee, "Fee recipient should receive protocol fee");
    }

    function testRevertBuyMarketplaceListingExpired() public {
        uint256 expiresAt = block.timestamp + 1 days;
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, expiresAt, address(0));

        vm.warp(expiresAt + 1);

        address nonPortfolioBuyer = address(0x9999);
        deal(USDC, nonPortfolioBuyer, LISTING_PRICE);

        vm.startPrank(nonPortfolioBuyer);
        usdc.approve(portfolioAccount, LISTING_PRICE);
        vm.expectRevert("Listing expired");
        BaseMarketplaceFacet(portfolioAccount).buyMarketplaceListing(tokenId, nonPortfolioBuyer);
        vm.stopPrank();
    }

    function testRevertBuyMarketplaceListingWrongBuyer() public {
        address allowedBuyer = address(0xAAAA);
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, allowedBuyer);

        address nonPortfolioBuyer = address(0x9999);
        deal(USDC, nonPortfolioBuyer, LISTING_PRICE);

        vm.startPrank(nonPortfolioBuyer);
        usdc.approve(portfolioAccount, LISTING_PRICE);
        vm.expectRevert("Buyer not allowed");
        BaseMarketplaceFacet(portfolioAccount).buyMarketplaceListing(tokenId, nonPortfolioBuyer);
        vm.stopPrank();
    }

    function testRevertBuyMarketplaceListingNoListing() public {
        address nonPortfolioBuyer = address(0x9999);
        deal(USDC, nonPortfolioBuyer, LISTING_PRICE);

        vm.startPrank(nonPortfolioBuyer);
        usdc.approve(portfolioAccount, LISTING_PRICE);
        vm.expectRevert("Listing does not exist");
        BaseMarketplaceFacet(portfolioAccount).buyMarketplaceListing(tokenId, nonPortfolioBuyer);
        vm.stopPrank();
    }

    function testRevertBuyMarketplaceListingBuyerIsPortfolio() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, address(0));

        address buyerPortfolio = portfolioFactory.portfolioOf(buyer);
        deal(USDC, buyerPortfolio, LISTING_PRICE);

        vm.startPrank(buyerPortfolio);
        usdc.approve(portfolioAccount, LISTING_PRICE);
        vm.expectRevert("Buyer cannot be a portfolio account");
        BaseMarketplaceFacet(portfolioAccount).buyMarketplaceListing(tokenId, buyerPortfolio);
        vm.stopPrank();
    }

    function testBuyMarketplaceListingWithRestrictedBuyerAllowed() public {
        address allowedBuyer = address(0xAAAA);
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, allowedBuyer);

        deal(USDC, allowedBuyer, LISTING_PRICE);

        vm.startPrank(allowedBuyer);
        usdc.approve(portfolioAccount, LISTING_PRICE);
        BaseMarketplaceFacet(portfolioAccount).buyMarketplaceListing(tokenId, allowedBuyer);
        vm.stopPrank();

        assertEq(veAERO.ownerOf(tokenId), allowedBuyer, "NFT should be transferred to allowed buyer");
    }

    // ============ Undercollateralization Enforcement Tests ============

    function testRevertPurchaseListingWouldCauseUndercollateralization() public {
        // Seller has two NFTs, borrows max, sells one NFT — should revert if undercollateralized

        // Add second token as collateral
        uint256 tokenId2 = 84298;
        address token2Owner = veAERO.ownerOf(tokenId2);
        vm.startPrank(token2Owner);
        veAERO.transferFrom(token2Owner, portfolioAccount, tokenId2);
        vm.stopPrank();
        addCollateralViaMulticall(tokenId2);

        // Get max loan with both tokens
        (, uint256 maxLoanIgnoreSupplyWithBoth) = DynamicCollateralFacet(portfolioAccount).getMaxLoan();
        assertGt(maxLoanIgnoreSupplyWithBoth, 0, "Seller should have collateral limit");

        // Seller borrows max loan
        borrowViaMulticall(maxLoanIgnoreSupplyWithBoth);

        uint256 sellerTotalDebt = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(sellerTotalDebt, maxLoanIgnoreSupplyWithBoth, "Seller should have borrowed amount");

        // Lower rewards rate to make seller undercollateralized after selling one NFT
        vm.startPrank(DEPLOYER);
        loanConfig.setRewardsRate(5000); // Lower rate
        vm.stopPrank();

        // Calculate maxLoan with only tokenId2 after rate decrease
        uint256 collateral2 = DynamicCollateralFacet(portfolioAccount).getLockedCollateral(tokenId2);
        uint256 rewardsRate = loanConfig.getRewardsRate();
        uint256 multiplier = loanConfig.getMultiplier();
        uint256 maxLoanIgnoreSupplyWithToken2Only = (((collateral2 * rewardsRate) / 1000000) * multiplier) / 1e12;

        // Attach less debt than needed to stay collateralized
        uint256 maxDebtToAttach = sellerTotalDebt > maxLoanIgnoreSupplyWithToken2Only
            ? sellerTotalDebt - maxLoanIgnoreSupplyWithToken2Only
            : 0;
        uint256 debtAttached = maxDebtToAttach > 0 ? maxDebtToAttach / 2 : sellerTotalDebt / 10;
        if (debtAttached == 0) debtAttached = 1;

        uint256 remainingDebtAfterSale = sellerTotalDebt - debtAttached;
        require(remainingDebtAfterSale > maxLoanIgnoreSupplyWithToken2Only, "Test setup: should cause undercollateralization");

        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, debtAttached, 0, address(0));

        // Buyer tries to buy — should revert due to seller undercollateralization
        vm.startPrank(buyer);
        usdc.approve(address(portfolioMarketplace), LISTING_PRICE);
        vm.expectRevert();
        portfolioMarketplace.purchaseListing(portfolioAccount, tokenId, USDC, LISTING_PRICE);
        vm.stopPrank();

        // Increase rewards rate — now purchase should succeed
        // Note: LoanConfig limits increases to 2x current value, so 5000 → max 10000
        vm.startPrank(DEPLOYER);
        loanConfig.setRewardsRate(10000); // Back to original rate (5000 * 2 = 10000 max)
        vm.stopPrank();

        uint256 newMaxLoanWithToken2Only = (((collateral2 * 10000) / 1000000) * multiplier) / 1e12;
        require(remainingDebtAfterSale <= newMaxLoanWithToken2Only, "Test setup: should not cause undercollateralization");

        vm.startPrank(buyer);
        usdc.approve(address(portfolioMarketplace), LISTING_PRICE);
        portfolioMarketplace.purchaseListing(portfolioAccount, tokenId, USDC, LISTING_PRICE);
        vm.stopPrank();

        address buyerPortfolio = portfolioFactory.portfolioOf(buyer);
        assertEq(veAERO.ownerOf(tokenId), buyerPortfolio, "NFT should be transferred after rate increase");
    }

    function testVulnerabilityAddDebtFromMarketplaceUndercollateralizedDebtNotTracked() public {
        // Verify that DynamicCollateralManager.addDebt properly tracks undercollateralizedDebt
        // when debt is transferred to a buyer with insufficient collateral
        address buyerPortfolio = portfolioFactory.portfolioOf(buyer);

        // Set rewards rate high for seller to borrow
        vm.startPrank(DEPLOYER);
        loanConfig.setRewardsRate(20000); // 2%
        vm.stopPrank();

        // Seller takes max loan
        (, uint256 sellerMaxLoanIgnoreSupply) = DynamicCollateralFacet(portfolioAccount).getMaxLoan();
        assertGt(sellerMaxLoanIgnoreSupply, 0, "Seller should have collateral limit");

        borrowViaMulticall(sellerMaxLoanIgnoreSupply);
        uint256 sellerTotalDebt = DynamicCollateralFacet(portfolioAccount).getTotalDebt();

        // List with all debt attached
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, sellerTotalDebt, 0, address(0));

        // Decrease rate so buyer would be undercollateralized
        vm.startPrank(DEPLOYER);
        loanConfig.setRewardsRate(10000); // Lower rate: 1%
        vm.stopPrank();

        uint256 sellerTokenCollateral = DynamicCollateralFacet(portfolioAccount).getLockedCollateral(tokenId);
        uint256 buyerCurrentCollateral = DynamicCollateralFacet(buyerPortfolio).getTotalLockedCollateral();
        uint256 buyerNewCollateral = buyerCurrentCollateral + sellerTokenCollateral;
        uint256 rewardsRate = loanConfig.getRewardsRate();
        uint256 multiplier = loanConfig.getMultiplier();
        uint256 buyerNewMaxLoanIgnoreSupply = (((buyerNewCollateral * rewardsRate) / 1000000) * multiplier) / 1e12;

        assertGt(sellerTotalDebt, buyerNewMaxLoanIgnoreSupply, "Debt should exceed buyer's new collateral limit");

        // Buyer tries to buy via FortyAcresMarketplaceFacet (multicall) — should REVERT
        // because addDebt now properly tracks undercollateralizedDebt
        deal(USDC, buyer, LISTING_PRICE);
        vm.startPrank(buyer);
        usdc.approve(buyerPortfolio, LISTING_PRICE);
        address[] memory pf = new address[](1);
        pf[0] = address(portfolioFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            portfolioAccount,
            tokenId,
            buyer
        );
        vm.expectRevert();
        portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    // ============ Partial Debt Payment Tests (Multiple NFTs) ============

    function testBuyMarketplaceListingPartialDebtPaymentMultipleNFTs() public {
        // Seller has 2 NFTs, borrows, sells one NFT without debt attached.
        // Only enough debt should be paid to stay in good standing.

        vm.startPrank(DEPLOYER);
        loanConfig.setRewardsRate(20000); // 2%
        vm.stopPrank();

        // Add second token as collateral
        uint256 tokenId2 = 84298;
        address token2Owner = veAERO.ownerOf(tokenId2);
        vm.startPrank(token2Owner);
        veAERO.transferFrom(token2Owner, portfolioAccount, tokenId2);
        vm.stopPrank();
        addCollateralViaMulticall(tokenId2);

        (, uint256 maxLoanBothTokens) = DynamicCollateralFacet(portfolioAccount).getMaxLoan();

        // Calculate maxLoan with only token2
        uint256 collateral2 = DynamicCollateralFacet(portfolioAccount).getLockedCollateral(tokenId2);
        uint256 rewardsRate = loanConfig.getRewardsRate();
        uint256 multiplier = loanConfig.getMultiplier();
        uint256 maxLoanToken2Only = (((collateral2 * rewardsRate) / 1000000) * multiplier) / 1e12;

        // Borrow between maxLoanToken2Only and maxLoanBothTokens
        uint256 borrowAmount = maxLoanToken2Only + (maxLoanBothTokens - maxLoanToken2Only) / 2;
        (uint256 maxLoanAvailable,) = DynamicCollateralFacet(portfolioAccount).getMaxLoan();
        if (borrowAmount > maxLoanAvailable) {
            borrowAmount = maxLoanAvailable;
        }
        borrowViaMulticall(borrowAmount);

        uint256 totalDebt = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        uint256 expectedRequiredPayment = totalDebt - maxLoanToken2Only;

        // List at price covering required payment + extra for seller
        uint256 extraForSeller = 500e6;
        uint256 listingPrice = expectedRequiredPayment + extraForSeller;

        makeListingViaMulticall(tokenId, listingPrice, USDC, 0, 0, address(0));

        address nonPortfolioBuyer = address(0x9999);
        deal(USDC, nonPortfolioBuyer, listingPrice);

        uint256 sellerBalanceBefore = usdc.balanceOf(user);

        vm.startPrank(nonPortfolioBuyer);
        usdc.approve(portfolioAccount, listingPrice);
        BaseMarketplaceFacet(portfolioAccount).buyMarketplaceListing(tokenId, nonPortfolioBuyer);
        vm.stopPrank();

        // Debt should be reduced to maxLoanToken2Only (not zero)
        uint256 debtAfter = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debtAfter, maxLoanToken2Only, "Debt should be reduced to maxLoanToken2Only");
        assertGt(debtAfter, 0, "Seller should still have debt remaining");

        // Seller should receive extra (listing price - protocol fee - required payment)
        uint256 sellerReceived = usdc.balanceOf(user) - sellerBalanceBefore;
        uint256 expectedProtocolFee = (listingPrice * PROTOCOL_FEE_BPS) / 10000;
        assertEq(sellerReceived, extraForSeller - expectedProtocolFee, "Seller should receive extra minus fee");

        assertEq(veAERO.ownerOf(tokenId), nonPortfolioBuyer, "NFT should be transferred");
    }

    function testPurchaseListingPartialDebtPaymentMultipleNFTs() public {
        // Portfolio buyer path — same scenario as above but via marketplace.purchaseListing

        vm.startPrank(DEPLOYER);
        loanConfig.setRewardsRate(20000); // 2%
        vm.stopPrank();

        uint256 tokenId2 = 84298;
        address token2Owner = veAERO.ownerOf(tokenId2);
        vm.startPrank(token2Owner);
        veAERO.transferFrom(token2Owner, portfolioAccount, tokenId2);
        vm.stopPrank();
        addCollateralViaMulticall(tokenId2);

        (, uint256 maxLoanBothTokens) = DynamicCollateralFacet(portfolioAccount).getMaxLoan();

        uint256 collateral2 = DynamicCollateralFacet(portfolioAccount).getLockedCollateral(tokenId2);
        uint256 rewardsRate = loanConfig.getRewardsRate();
        uint256 multiplier = loanConfig.getMultiplier();
        uint256 maxLoanToken2Only = (((collateral2 * rewardsRate) / 1000000) * multiplier) / 1e12;

        uint256 borrowAmount = maxLoanToken2Only + (maxLoanBothTokens - maxLoanToken2Only) / 2;
        (uint256 maxLoanAvailable,) = DynamicCollateralFacet(portfolioAccount).getMaxLoan();
        if (borrowAmount > maxLoanAvailable) {
            borrowAmount = maxLoanAvailable;
        }
        borrowViaMulticall(borrowAmount);

        uint256 totalDebt = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        uint256 expectedRequiredPayment = totalDebt - maxLoanToken2Only;

        uint256 extraForSeller = 500e6;
        uint256 listingPrice = expectedRequiredPayment + extraForSeller;

        makeListingViaMulticall(tokenId, listingPrice, USDC, 0, 0, address(0));

        deal(USDC, buyer, listingPrice);
        uint256 sellerBalanceBefore = usdc.balanceOf(user);

        vm.startPrank(buyer);
        usdc.approve(address(portfolioMarketplace), listingPrice);
        portfolioMarketplace.purchaseListing(portfolioAccount, tokenId, USDC, listingPrice);
        vm.stopPrank();

        uint256 expectedProtocolFee = (listingPrice * PROTOCOL_FEE_BPS) / 10000;
        uint256 paymentAfterFee = listingPrice - expectedProtocolFee;

        // Debt reduced to maxLoanToken2Only
        uint256 debtAfter = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertGt(debtAfter, 0, "Seller should still have debt remaining");
        assertEq(debtAfter, maxLoanToken2Only, "Debt should be reduced to maxLoanToken2Only");

        // Seller receives paymentAfterFee minus requiredPayment
        uint256 sellerReceived = usdc.balanceOf(user) - sellerBalanceBefore;
        assertEq(sellerReceived, paymentAfterFee - expectedRequiredPayment, "Seller should receive excess");

        address buyerPortfolio = portfolioFactory.portfolioOf(buyer);
        assertEq(veAERO.ownerOf(tokenId), buyerPortfolio, "NFT should be in buyer's portfolio");
    }

    function testBuyMarketplaceListingNoDebtPaymentNeeded() public {
        // When debt is small enough that remaining collateral covers it, no debt payment needed

        vm.startPrank(DEPLOYER);
        loanConfig.setRewardsRate(20000); // 2%
        vm.stopPrank();

        uint256 tokenId2 = 84298;
        address token2Owner = veAERO.ownerOf(tokenId2);
        vm.startPrank(token2Owner);
        veAERO.transferFrom(token2Owner, portfolioAccount, tokenId2);
        vm.stopPrank();
        addCollateralViaMulticall(tokenId2);

        // Calculate maxLoan with only token2
        uint256 collateral2 = DynamicCollateralFacet(portfolioAccount).getLockedCollateral(tokenId2);
        uint256 rewardsRate = loanConfig.getRewardsRate();
        uint256 multiplier = loanConfig.getMultiplier();
        uint256 maxLoanToken2Only = (((collateral2 * rewardsRate) / 1000000) * multiplier) / 1e12;

        // Borrow small amount that token2 alone can cover
        uint256 borrowAmount = maxLoanToken2Only / 2;
        require(borrowAmount > 0, "Borrow amount must be positive");
        borrowViaMulticall(borrowAmount);

        uint256 totalDebt = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertGt(totalDebt, 0, "Should have debt");

        uint256 listingPrice = 1000e6;
        makeListingViaMulticall(tokenId, listingPrice, USDC, 0, 0, address(0));

        address nonPortfolioBuyer = address(0x9999);
        deal(USDC, nonPortfolioBuyer, listingPrice);

        uint256 sellerBalanceBefore = usdc.balanceOf(user);
        uint256 debtBefore = DynamicCollateralFacet(portfolioAccount).getTotalDebt();

        vm.startPrank(nonPortfolioBuyer);
        usdc.approve(portfolioAccount, listingPrice);
        BaseMarketplaceFacet(portfolioAccount).buyMarketplaceListing(tokenId, nonPortfolioBuyer);
        vm.stopPrank();

        // Debt should NOT change
        uint256 debtAfter = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debtAfter, debtBefore, "Debt should not change when remaining collateral covers it");

        // Seller gets full listing price minus protocol fee
        uint256 sellerReceived = usdc.balanceOf(user) - sellerBalanceBefore;
        uint256 expectedProtocolFee = (listingPrice * PROTOCOL_FEE_BPS) / 10000;
        assertEq(sellerReceived, listingPrice - expectedProtocolFee, "Seller should receive full price minus fee");

        assertEq(veAERO.ownerOf(tokenId), nonPortfolioBuyer, "NFT should be transferred");
    }

    // ============ Protocol Fee Tests ============

    function testProtocolFeeIsCalculatedCorrectly() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, address(0));

        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 expectedProtocolFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;

        vm.startPrank(buyer);
        usdc.approve(address(portfolioMarketplace), LISTING_PRICE);
        portfolioMarketplace.purchaseListing(portfolioAccount, tokenId, USDC, LISTING_PRICE);
        vm.stopPrank();

        uint256 feeReceived = usdc.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertEq(feeReceived, expectedProtocolFee, "Fee recipient should receive correct protocol fee");
    }

    function testProtocolFeeIsDeductedFromPayment() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, address(0));

        uint256 sellerBalanceBefore = usdc.balanceOf(user);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        vm.startPrank(buyer);
        usdc.approve(address(portfolioMarketplace), LISTING_PRICE);
        portfolioMarketplace.purchaseListing(portfolioAccount, tokenId, USDC, LISTING_PRICE);
        vm.stopPrank();

        uint256 expectedProtocolFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        uint256 expectedPaymentToSeller = LISTING_PRICE - expectedProtocolFee;

        uint256 sellerReceived = usdc.balanceOf(user) - sellerBalanceBefore;
        assertEq(sellerReceived, expectedPaymentToSeller, "Seller should receive payment minus fee");

        uint256 feeReceived = usdc.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertEq(feeReceived, expectedProtocolFee, "Fee recipient should receive protocol fee");

        assertEq(sellerReceived + feeReceived, LISTING_PRICE, "Total distribution should equal listing price");
    }

    function testProtocolFeeWithDebtAttached() public {
        uint256 borrowAmount = 300e6;
        borrowViaMulticall(borrowAmount);

        uint256 totalDebt = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, totalDebt, 0, address(0));

        uint256 sellerBalanceBefore = usdc.balanceOf(user);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        vm.startPrank(buyer);
        usdc.approve(address(portfolioMarketplace), LISTING_PRICE);
        portfolioMarketplace.purchaseListing(portfolioAccount, tokenId, USDC, LISTING_PRICE);
        vm.stopPrank();

        uint256 expectedProtocolFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        uint256 paymentAfterFee = LISTING_PRICE - expectedProtocolFee;

        uint256 feeReceived = usdc.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertEq(feeReceived, expectedProtocolFee, "Fee should be taken even with debt attached");

        // With debt attached, seller receives full payment after fee (debt is transferred, not paid)
        uint256 sellerReceived = usdc.balanceOf(user) - sellerBalanceBefore;
        assertApproxEqRel(sellerReceived, paymentAfterFee, 1e15, "Seller should receive payment minus fee");
    }

    function testProtocolFeeWithZeroFee() public {
        // Set protocol fee to 0
        vm.startPrank(DEPLOYER);
        portfolioMarketplace.setProtocolFee(0);
        vm.stopPrank();

        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, address(0));

        uint256 sellerBalanceBefore = usdc.balanceOf(user);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        vm.startPrank(buyer);
        usdc.approve(address(portfolioMarketplace), LISTING_PRICE);
        portfolioMarketplace.purchaseListing(portfolioAccount, tokenId, USDC, LISTING_PRICE);
        vm.stopPrank();

        uint256 feeReceived = usdc.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertEq(feeReceived, 0, "No fee when protocol fee is 0");

        uint256 sellerReceived = usdc.balanceOf(user) - sellerBalanceBefore;
        assertEq(sellerReceived, LISTING_PRICE, "Seller should receive full payment");
    }

    // ============ buyMarketplaceListing Protocol Fee Tests ============

    function testBuyMarketplaceListingProtocolFeeCollected() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, address(0));

        address nonPortfolioBuyer = address(0x9999);
        deal(USDC, nonPortfolioBuyer, LISTING_PRICE);

        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 sellerBalanceBefore = usdc.balanceOf(user);
        uint256 buyerBalanceBefore = usdc.balanceOf(nonPortfolioBuyer);

        uint256 expectedProtocolFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        uint256 expectedSellerPayment = LISTING_PRICE - expectedProtocolFee;

        vm.startPrank(nonPortfolioBuyer);
        usdc.approve(portfolioAccount, LISTING_PRICE);
        BaseMarketplaceFacet(portfolioAccount).buyMarketplaceListing(tokenId, nonPortfolioBuyer);
        vm.stopPrank();

        uint256 feeReceived = usdc.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertEq(feeReceived, expectedProtocolFee, "Fee recipient should receive protocol fee");

        uint256 sellerReceived = usdc.balanceOf(user) - sellerBalanceBefore;
        assertEq(sellerReceived, expectedSellerPayment, "Seller should receive payment minus fee");

        uint256 buyerPaid = buyerBalanceBefore - usdc.balanceOf(nonPortfolioBuyer);
        assertEq(buyerPaid, LISTING_PRICE, "Buyer should pay full listing price");

        assertEq(feeReceived + sellerReceived, LISTING_PRICE, "Total distribution should equal listing price");
    }

    function testBuyMarketplaceListingProtocolFeeWithDebtAttached() public {
        uint256 borrowAmount = 300e6;
        borrowViaMulticall(borrowAmount);

        uint256 totalDebt = DynamicCollateralFacet(portfolioAccount).getTotalDebt();

        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, totalDebt, 0, address(0));

        address nonPortfolioBuyer = address(0x9999);
        deal(USDC, nonPortfolioBuyer, LISTING_PRICE + totalDebt);

        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 sellerBalanceBefore = usdc.balanceOf(user);
        uint256 buyerBalanceBefore = usdc.balanceOf(nonPortfolioBuyer);

        uint256 expectedProtocolFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        uint256 expectedSellerPayment = LISTING_PRICE - expectedProtocolFee;

        vm.startPrank(nonPortfolioBuyer);
        usdc.approve(portfolioAccount, LISTING_PRICE + totalDebt);
        BaseMarketplaceFacet(portfolioAccount).buyMarketplaceListing(tokenId, nonPortfolioBuyer);
        vm.stopPrank();

        uint256 feeReceived = usdc.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertEq(feeReceived, expectedProtocolFee, "Fee should be taken with debt attached");

        uint256 sellerReceived = usdc.balanceOf(user) - sellerBalanceBefore;
        assertEq(sellerReceived, expectedSellerPayment, "Seller should receive payment minus fee");

        uint256 debtAfter = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debtAfter, 0, "Debt should be fully paid");

        uint256 buyerPaid = buyerBalanceBefore - usdc.balanceOf(nonPortfolioBuyer);
        assertEq(buyerPaid, LISTING_PRICE + totalDebt, "Buyer should pay listing price + debt");
    }

    function testBuyMarketplaceListingZeroProtocolFee() public {
        vm.startPrank(DEPLOYER);
        portfolioMarketplace.setProtocolFee(0);
        vm.stopPrank();

        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, 0, address(0));

        address nonPortfolioBuyer = address(0x9999);
        deal(USDC, nonPortfolioBuyer, LISTING_PRICE);

        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 sellerBalanceBefore = usdc.balanceOf(user);

        vm.startPrank(nonPortfolioBuyer);
        usdc.approve(portfolioAccount, LISTING_PRICE);
        BaseMarketplaceFacet(portfolioAccount).buyMarketplaceListing(tokenId, nonPortfolioBuyer);
        vm.stopPrank();

        uint256 feeReceived = usdc.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertEq(feeReceived, 0, "No fee when protocol fee is 0");

        uint256 sellerReceived = usdc.balanceOf(user) - sellerBalanceBefore;
        assertEq(sellerReceived, LISTING_PRICE, "Seller should receive full listing price");
    }
}
