// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {DynamicMarketplaceFacet} from "../../../../src/facets/account/marketplace/DynamicMarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../../src/facets/marketplace/PortfolioMarketplace.sol";
import {IMarketplaceFacet} from "../../../../src/interfaces/IMarketplaceFacet.sol";
import {DynamicCollateralFacet} from "../../../../src/facets/account/collateral/DynamicCollateralFacet.sol";
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {DynamicLendingFacet} from "../../../../src/facets/account/lending/DynamicLendingFacet.sol";
import {BaseLendingFacet} from "../../../../src/facets/account/lending/BaseLendingFacet.sol";
import {DynamicVotingEscrowFacet} from "../../../../src/facets/account/votingEscrow/DynamicVotingEscrowFacet.sol";
import {FortyAcresMarketplaceFacet} from "../../../../src/facets/account/marketplace/FortyAcresMarketplaceFacet.sol";
import {WalletFacet} from "../../../../src/facets/account/wallet/WalletFacet.sol";
import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioAccountConfig} from "../../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {SwapConfig} from "../../../../src/facets/account/config/SwapConfig.sol";
import {DeployPortfolioAccountConfig} from "../../../../script/portfolio_account/DeployPortfolioAccountConfig.s.sol";
import {DynamicFeesVault} from "../../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DynamicMarketplaceFacetTest
 * @dev Marketplace tests for diamonds using DynamicFeesVault + DynamicMarketplaceFacet.
 *      Key differences from standard marketplace tests:
 *      - Debt is tracked in DynamicFeesVault, not locally
 *      - No unpaid fees (getUnpaidFees() always returns 0)
 *      - Sale proceeds pay debt via receiveSaleProceeds (partial paydown)
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

    // Wallet factory (for buying facets)
    PortfolioFactory public walletFactory;
    FacetRegistry public walletFacetRegistry;
    SwapConfig public swapConfig;

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
        portfolioAccountConfig.setPortfolioFactory(address(portfolioFactory));
        portfolioManager.setAuthorizedCaller(address(0xaaaaa), true);

        // Deploy PortfolioMarketplace
        portfolioMarketplace = new PortfolioMarketplace(
            address(portfolioManager),
            VOTING_ESCROW,
            PROTOCOL_FEE_BPS,
            feeRecipient
        );
        portfolioMarketplace.setAllowedPaymentToken(USDC, true);

        // Deploy all facets
        _deployFacets();

        // Deploy wallet factory for buying facets
        (walletFactory, walletFacetRegistry) = portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("wallet")))
        );

        swapConfig = new SwapConfig();

        WalletFacet walletFacet = new WalletFacet(
            address(walletFactory),
            address(portfolioAccountConfig),
            address(swapConfig)
        );
        bytes4[] memory walletSelectors = new bytes4[](6);
        walletSelectors[0] = WalletFacet.transferERC20.selector;
        walletSelectors[1] = WalletFacet.transferNFT.selector;
        walletSelectors[2] = WalletFacet.receiveERC20.selector;
        walletSelectors[3] = WalletFacet.swap.selector;
        walletSelectors[4] = WalletFacet.enforceCollateralRequirements.selector;
        walletSelectors[5] = WalletFacet.onERC721Received.selector;
        walletFacetRegistry.registerFacet(address(walletFacet), walletSelectors, "WalletFacet");

        FortyAcresMarketplaceFacet walletFortyAcresFacet = new FortyAcresMarketplaceFacet(
            address(walletFactory),
            address(portfolioAccountConfig),
            VOTING_ESCROW,
            address(portfolioMarketplace)
        );
        bytes4[] memory walletFortyAcresSelectors = new bytes4[](1);
        walletFortyAcresSelectors[0] = FortyAcresMarketplaceFacet.buyFortyAcresListing.selector;
        walletFacetRegistry.registerFacet(address(walletFortyAcresFacet), walletFortyAcresSelectors, "FortyAcresMarketplaceFacet");

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
        bytes4[] memory votingEscrowSelectors = new bytes4[](4);
        votingEscrowSelectors[0] = DynamicVotingEscrowFacet.increaseLock.selector;
        votingEscrowSelectors[1] = DynamicVotingEscrowFacet.createLock.selector;
        votingEscrowSelectors[2] = DynamicVotingEscrowFacet.merge.selector;
        votingEscrowSelectors[3] = DynamicVotingEscrowFacet.onERC721Received.selector;
        facetRegistry.registerFacet(address(votingEscrowFacet), votingEscrowSelectors, "DynamicVotingEscrowFacet");

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
        bytes4[] memory marketplaceSelectors = new bytes4[](6);
        marketplaceSelectors[0] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        marketplaceSelectors[1] = BaseMarketplaceFacet.makeListing.selector;
        marketplaceSelectors[2] = BaseMarketplaceFacet.cancelListing.selector;
        marketplaceSelectors[3] = BaseMarketplaceFacet.marketplace.selector;
        marketplaceSelectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        marketplaceSelectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        facetRegistry.registerFacet(address(marketplaceFacet), marketplaceSelectors, "DynamicMarketplaceFacet");
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

    function purchaseListingViaMulticall(
        address buyerEoa,
        uint256 _tokenId,
        uint256 price
    ) internal {
        uint256 nonce = portfolioMarketplace.getListing(_tokenId).nonce;
        address buyerWalletPortfolio = walletFactory.portfolioOf(buyerEoa);
        if (buyerWalletPortfolio == address(0)) {
            buyerWalletPortfolio = walletFactory.createAccount(buyerEoa);
        }
        // Fund wallet portfolio with payment token
        if (IERC20(USDC).balanceOf(buyerWalletPortfolio) < price) {
            deal(USDC, buyerWalletPortfolio, price);
        }
        vm.startPrank(buyerEoa);
        address[] memory pf = new address[](1);
        pf[0] = address(walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            _tokenId,
            nonce
        );
        portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    // ============ Listing CRUD Tests ============

    function testCreateListing() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, address(0));

        // Verify local sale authorization
        (uint256 price, address paymentToken) = IMarketplaceFacet(portfolioAccount).getSaleAuthorization(tokenId);
        assertEq(price, LISTING_PRICE);
        assertEq(paymentToken, USDC);

        // Verify centralized listing
        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(tokenId);
        assertEq(listing.price, LISTING_PRICE);
        assertEq(listing.paymentToken, USDC);
    }

    function testCreateListingWithExpiration() public {
        uint256 expiresAt = block.timestamp + 7 days;
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, expiresAt, address(0));

        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(tokenId);
        assertEq(listing.expiresAt, expiresAt);
    }

    function testCreateListingWithAllowedBuyer() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, buyer);

        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(tokenId);
        assertEq(listing.allowedBuyer, buyer);
    }

    function testCancelListing() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, address(0));

        vm.startPrank(user);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseMarketplaceFacet.cancelListing.selector, tokenId);
        portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        assertFalse(IMarketplaceFacet(portfolioAccount).hasSaleAuthorization(tokenId), "Sale authorization should be removed");
        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(tokenId);
        assertEq(listing.owner, address(0), "Centralized listing should be removed");
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
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, address(0));

        vm.startPrank(user);
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            BaseMarketplaceFacet.makeListing.selector, tokenId, LISTING_PRICE * 2, USDC, 0, address(0)
        );
        vm.expectRevert("Listing already exists");
        portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    function testGetListing() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, address(0));

        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(tokenId);
        assertEq(listing.price, LISTING_PRICE);
        assertEq(listing.paymentToken, USDC);
    }

    function testCannotRemoveCollateralWhenListed() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, address(0));

        vm.expectRevert(abi.encodeWithSelector(BaseCollateralFacet.ListingActive.selector, tokenId));
        removeCollateralViaMulticall(tokenId);
    }

    // ============ P2P Purchase Tests (via PortfolioMarketplace.purchaseListing) ============

    function testPurchaseListing() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, address(0));

        uint256 sellerBalanceBefore = usdc.balanceOf(user);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        purchaseListingViaMulticall(buyer, tokenId, LISTING_PRICE);

        address buyerWalletPortfolio = walletFactory.portfolioOf(buyer);

        assertEq(veAERO.ownerOf(tokenId), buyerWalletPortfolio, "NFT should be in buyer's wallet portfolio");

        uint256 expectedProtocolFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        uint256 paymentAfterFee = LISTING_PRICE - expectedProtocolFee;

        uint256 feeReceived = usdc.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertEq(feeReceived, expectedProtocolFee, "Fee recipient should receive protocol fee");

        uint256 sellerReceived = usdc.balanceOf(user) - sellerBalanceBefore;
        assertEq(sellerReceived, paymentAfterFee, "Seller should receive payment minus protocol fee");

        // Wallet portfolio should have spent the listing price
        assertEq(usdc.balanceOf(buyerWalletPortfolio), 0, "Buyer wallet should have spent all funds");

        // Verify both authorizations cleaned up
        assertFalse(IMarketplaceFacet(portfolioAccount).hasSaleAuthorization(tokenId), "Sale authorization should be removed");
        PortfolioMarketplace.Listing memory listing = portfolioMarketplace.getListing(tokenId);
        assertEq(listing.owner, address(0), "Centralized listing should be removed");
    }

    function testPurchaseListingWithDebtPaydown() public {
        uint256 borrowAmount = 300e6;
        borrowViaMulticall(borrowAmount);

        uint256 totalDebt = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertGt(totalDebt, 0, "Should have debt");

        // Listing without debt attached — proceeds pay debt via receiveSaleProceeds
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, address(0));

        uint256 sellerBalanceBefore = usdc.balanceOf(user);

        purchaseListingViaMulticall(buyer, tokenId, LISTING_PRICE);

        // With only one NFT, all debt must be paid to remove collateral
        uint256 debtAfter = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debtAfter, 0, "Seller should have no debt after sale (single NFT)");

        address buyerWalletPortfolio = walletFactory.portfolioOf(buyer);
        assertEq(veAERO.ownerOf(tokenId), buyerWalletPortfolio, "NFT should be in buyer's wallet portfolio");
    }

    function testPurchaseListingWithRestrictedBuyer() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, buyer);

        purchaseListingViaMulticall(buyer, tokenId, LISTING_PRICE);

        address buyerWalletPortfolio = walletFactory.portfolioOf(buyer);
        assertEq(veAERO.ownerOf(tokenId), buyerWalletPortfolio, "NFT should be in buyer's wallet portfolio");
    }

    function testRevertPurchaseListingByRestrictedBuyer() public {
        address otherBuyer = address(0x9999);

        address otherBuyerWallet = walletFactory.createAccount(otherBuyer);
        deal(USDC, otherBuyerWallet, LISTING_PRICE);

        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, buyer);

        uint256 nonce = portfolioMarketplace.getListing(tokenId).nonce;
        vm.startPrank(otherBuyer);
        address[] memory pf = new address[](1);
        pf[0] = address(walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            tokenId,
            nonce
        );
        vm.expectRevert(PortfolioMarketplace.BuyerNotAllowed.selector);
        portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function testRevertPurchaseExpiredListing() public {
        uint256 expiresAt = block.timestamp + 1 days;
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, expiresAt, address(0));

        uint256 nonce = portfolioMarketplace.getListing(tokenId).nonce;
        vm.warp(expiresAt + 1);

        address buyerWallet = walletFactory.portfolioOf(buyer);
        if (buyerWallet == address(0)) {
            buyerWallet = walletFactory.createAccount(buyer);
        }
        deal(USDC, buyerWallet, LISTING_PRICE);
        vm.startPrank(buyer);
        address[] memory pf = new address[](1);
        pf[0] = address(walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            tokenId,
            nonce
        );
        vm.expectRevert(PortfolioMarketplace.ListingExpired.selector);
        portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function testRevertPurchaseWithInsufficientBalance() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, address(0));

        uint256 nonce = portfolioMarketplace.getListing(tokenId).nonce;
        address buyerWallet = walletFactory.portfolioOf(buyer);
        if (buyerWallet == address(0)) {
            buyerWallet = walletFactory.createAccount(buyer);
        }
        // Fund wallet with less than listing price
        deal(USDC, buyerWallet, LISTING_PRICE - 1);
        vm.startPrank(buyer);
        address[] memory pf = new address[](1);
        pf[0] = address(walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            tokenId,
            nonce
        );
        vm.expectRevert("Insufficient balance");
        portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    function testRevertPurchaseNonExistentListing() public {
        address buyerWallet = walletFactory.portfolioOf(buyer);
        if (buyerWallet == address(0)) {
            buyerWallet = walletFactory.createAccount(buyer);
        }
        deal(USDC, buyerWallet, LISTING_PRICE);
        vm.startPrank(buyer);
        address[] memory pf = new address[](1);
        pf[0] = address(walletFactory);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            tokenId,
            uint256(0)
        );
        vm.expectRevert("Listing does not exist");
        portfolioManager.multicall(cd, pf);
        vm.stopPrank();
    }

    // ============ Partial Debt Payment Tests (Multiple NFTs) ============

    function testPurchaseListingPartialDebtPaymentMultipleNFTs() public {
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

        makeListingViaMulticall(tokenId, listingPrice, USDC, 0, address(0));

        deal(USDC, buyer, listingPrice);
        uint256 sellerBalanceBefore = usdc.balanceOf(user);

        purchaseListingViaMulticall(buyer, tokenId, listingPrice);

        uint256 expectedProtocolFee = (listingPrice * PROTOCOL_FEE_BPS) / 10000;
        uint256 paymentAfterFee = listingPrice - expectedProtocolFee;

        uint256 debtAfter = DynamicCollateralFacet(portfolioAccount).getTotalDebt();
        assertGt(debtAfter, 0, "Seller should still have debt remaining");
        assertEq(debtAfter, maxLoanToken2Only, "Debt should be reduced to maxLoanToken2Only");

        uint256 sellerReceived = usdc.balanceOf(user) - sellerBalanceBefore;
        assertEq(sellerReceived, paymentAfterFee - expectedRequiredPayment, "Seller should receive excess");

        address buyerWalletPortfolio = walletFactory.portfolioOf(buyer);
        assertEq(veAERO.ownerOf(tokenId), buyerWalletPortfolio, "NFT should be in buyer's wallet portfolio");
    }

    // ============ Protocol Fee Tests ============

    function testProtocolFeeIsCalculatedCorrectly() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, address(0));

        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 expectedProtocolFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;

        purchaseListingViaMulticall(buyer, tokenId, LISTING_PRICE);

        uint256 feeReceived = usdc.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertEq(feeReceived, expectedProtocolFee, "Fee recipient should receive correct protocol fee");
    }

    function testProtocolFeeIsDeductedFromPayment() public {
        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, address(0));

        uint256 sellerBalanceBefore = usdc.balanceOf(user);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        purchaseListingViaMulticall(buyer, tokenId, LISTING_PRICE);

        uint256 expectedProtocolFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        uint256 expectedPaymentToSeller = LISTING_PRICE - expectedProtocolFee;

        uint256 sellerReceived = usdc.balanceOf(user) - sellerBalanceBefore;
        assertEq(sellerReceived, expectedPaymentToSeller, "Seller should receive payment minus fee");

        uint256 feeReceived = usdc.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertEq(feeReceived, expectedProtocolFee, "Fee recipient should receive protocol fee");

        assertEq(sellerReceived + feeReceived, LISTING_PRICE, "Total distribution should equal listing price");
    }

    function testProtocolFeeWithZeroFee() public {
        vm.startPrank(DEPLOYER);
        portfolioMarketplace.setProtocolFee(0);
        vm.stopPrank();

        makeListingViaMulticall(tokenId, LISTING_PRICE, USDC, 0, address(0));

        uint256 sellerBalanceBefore = usdc.balanceOf(user);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        purchaseListingViaMulticall(buyer, tokenId, LISTING_PRICE);

        uint256 feeReceived = usdc.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        assertEq(feeReceived, 0, "No fee when protocol fee is 0");

        uint256 sellerReceived = usdc.balanceOf(user) - sellerBalanceBefore;
        assertEq(sellerReceived, LISTING_PRICE, "Seller should receive full payment");
    }

}
