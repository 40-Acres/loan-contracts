// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {VeHydrexDiamond, HydrexCollateralFacet} from "./helpers/VeHydrexDiamond.sol";

import {HydrexMarketplaceFacet} from "../../../src/facets/account/veHydrex/HydrexMarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {FortyAcresMarketplaceFacet} from "../../../src/facets/account/marketplace/FortyAcresMarketplaceFacet.sol";
import {IMarketplaceFacet} from "../../../src/interfaces/IMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../src/facets/marketplace/PortfolioMarketplace.sol";

import {VeHydrexVotingEscrowFacet} from "../../../src/facets/account/veHydrex/VeHydrexVotingEscrowFacet.sol";
import {WalletFacet} from "../../../src/facets/account/wallet/WalletFacet.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";

import {IHydrexVotingEscrow} from "../../../src/interfaces/IHydrexVotingEscrow.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockLendingPool, MockVaultShell} from "./mocks/MockLendingPool.sol";

/// @notice MockLendingPool variant that exposes the `_asset` / `_vault` selectors
///         expected by PortfolioFactoryConfig.getDebtToken / getVault.
contract MockLendingPoolWithAsset is MockLendingPool {
    constructor(address asset_, address vault_, address factory_) MockLendingPool(asset_, vault_, factory_) {}
    function _asset() external view returns (address) { return _lendingAsset; }
}

/// @dev End-to-end veHydrex marketplace flow. Validates that HydrexMarketplaceFacet's
///      collateral / debt overrides route through HydrexCollateralManager's storage
///      slot, and that the BaseMarketplaceFacet logic behaves identically to the
///      Velo path it inherits from.
contract HydrexMarketplaceFacetTest is VeHydrexDiamond {
    HydrexMarketplaceFacet internal marketplaceFacet;
    PortfolioMarketplace internal portfolioMarketplace;

    // Buyer factory + buyer EOA / portfolio.
    PortfolioFactory internal walletFactory;
    FacetRegistry internal walletFacetRegistry;
    SwapConfig internal swapConfigForWallet;
    PortfolioFactoryConfig internal walletFactoryConfig;
    address internal buyer = address(0xB0FF);
    address internal feeRecipient = address(0xFEE);

    // Constants mirror MarketplaceFacet.t.sol where applicable.
    uint256 internal constant LISTING_PRICE = 1000e6; // 1000 USDC
    uint256 internal constant PROTOCOL_FEE_BPS = 100; // 1%

    function setUp() public {
        // Pin timestamp away from epoch boundaries the rest of the hydrex suite
        // uses for vesting/checkpoint math.
        vm.warp(100 weeks);
        _bootstrap();

        // Swap in a lending pool that implements `_asset()` so getDebtToken
        // resolves. The harness's default MockLendingPool does not expose it.
        vm.startPrank(owner_);
        MockLendingPoolWithAsset newPool = new MockLendingPoolWithAsset(
            address(usdc), address(vault), address(portfolioFactory)
        );
        portfolioFactoryConfig.setLoanContract(address(newPool));
        // Allow real-money borrow paths: pool transfers USDC out on borrow.
        newPool.setTransferOnBorrow(true);
        // Seed pool with enough USDC to cover any borrow we issue in tests.
        usdc.mint(address(newPool), 10_000_000e6);
        vm.stopPrank();
        // Rebind to the new pool object so tests that need its API can call it.
        lendingPool = MockLendingPool(address(newPool));

        // PortfolioMarketplace owned by the test contract so we can configure
        // protocolFee / feeRecipient / allowed payment tokens.
        portfolioMarketplace = new PortfolioMarketplace(
            address(portfolioManager),
            address(ve),
            PROTOCOL_FEE_BPS,
            feeRecipient,
            address(this) // owner = test
        );
        portfolioMarketplace.setAllowedPaymentToken(address(usdc), true);

        // Register HydrexMarketplaceFacet on the seller's hydrex factory.
        marketplaceFacet = new HydrexMarketplaceFacet(
            address(portfolioFactory), address(ve), address(portfolioMarketplace)
        );
        vm.startPrank(owner_);
        {
            bytes4[] memory s = new bytes4[](8);
            // Selector list mirrors DeployVeHydrexMarketplace._hydrexMarketplaceSelectors.
            s[0] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
            s[1] = BaseMarketplaceFacet.makeListing.selector;
            s[2] = BaseMarketplaceFacet.cancelListing.selector;
            s[3] = BaseMarketplaceFacet.marketplace.selector;
            s[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
            s[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
            s[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
            s[7] = BaseMarketplaceFacet.isListingPurchasable.selector;
            facetRegistry.registerFacet(address(marketplaceFacet), s, "HydrexMarketplaceFacet");
        }

        // ----- Buyer wallet factory -----
        (walletFactory, walletFacetRegistry) = portfolioManager.deployFactory(
            keccak256(abi.encodePacked("hydrex-marketplace-buyer-wallet", block.timestamp))
        );

        // WalletFacet needs a non-zero SwapConfig; minimal upgradeable deploy.
        SwapConfig swapImpl = new SwapConfig();
        ERC1967Proxy swapProxy = new ERC1967Proxy(
            address(swapImpl),
            abi.encodeCall(SwapConfig.initialize, (owner_))
        );
        swapConfigForWallet = SwapConfig(address(swapProxy));

        WalletFacet walletFacet = new WalletFacet(
            address(walletFactory), address(swapConfigForWallet)
        );
        {
            // Only the surface the marketplace flow requires:
            // - onERC721Received for the incoming veNFT
            // - enforceCollateralRequirements for the multicall post-check
            bytes4[] memory s = new bytes4[](2);
            s[0] = WalletFacet.onERC721Received.selector;
            s[1] = WalletFacet.enforceCollateralRequirements.selector;
            walletFacetRegistry.registerFacet(address(walletFacet), s, "WalletFacet");
        }

        FortyAcresMarketplaceFacet fortyAcresFacet = new FortyAcresMarketplaceFacet(
            address(walletFactory), address(ve), address(portfolioMarketplace)
        );
        {
            // Pure addition: register the new buyFortyAcresListingFrom selector
            // alongside the original. No existing test calls this selector, so
            // existing behavior is unchanged.
            bytes4[] memory s = new bytes4[](2);
            s[0] = FortyAcresMarketplaceFacet.buyFortyAcresListing.selector;
            s[1] = FortyAcresMarketplaceFacet.buyFortyAcresListingFrom.selector;
            walletFacetRegistry.registerFacet(address(fortyAcresFacet), s, "FortyAcresMarketplaceFacet");
        }

        // Pure addition: wire a minimal PortfolioFactoryConfig onto the buyer
        // wallet factory. deployFactory does NOT set one, and
        // buyFortyAcresListingFrom reads walletFactory.portfolioFactoryConfig().
        // Without this the new path would revert calling into address(0) before
        // ever reaching the allowlist check.
        PortfolioFactoryConfig walletConfigImpl = new PortfolioFactoryConfig();
        ERC1967Proxy walletConfigProxy = new ERC1967Proxy(address(walletConfigImpl), "");
        walletFactoryConfig = PortfolioFactoryConfig(address(walletConfigProxy));
        walletFactoryConfig.initialize(owner_, address(walletFactory));
        walletFactory.setPortfolioFactoryConfig(address(walletFactoryConfig));
        vm.stopPrank();

        // Create buyer's wallet portfolio and fund it generously.
        vm.prank(buyer);
        walletFactory.createAccount(buyer);
        address buyerWallet = walletFactory.portfolioOf(buyer);
        usdc.mint(buyerWallet, LISTING_PRICE * 4);
    }

    // ────────────────────────────────────────────────────────────
    // Helpers
    // ────────────────────────────────────────────────────────────

    function _seedRollingLock(uint256 amount) internal returns (uint256 tokenId) {
        underlying.mint(user, amount);
        vm.startPrank(user);
        underlying.approve(portfolioAccount, type(uint256).max);
        vm.stopPrank();
        vm.startPrank(portfolioAccount);
        underlying.approve(address(ve), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(
                VeHydrexVotingEscrowFacet.createLock.selector,
                amount,
                IHydrexVotingEscrow.LockType.ROLLING
            )
        );
        bytes[] memory results = portfolioManager.multicall(cd, fac);
        tokenId = abi.decode(results[0], (uint256));
        vm.stopPrank();
    }

    function _makeListing(
        uint256 tokenId,
        uint256 price,
        uint256 expiresAt,
        address allowedBuyer
    ) internal {
        vm.startPrank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(
                BaseMarketplaceFacet.makeListing.selector,
                tokenId,
                price,
                address(usdc),
                expiresAt,
                allowedBuyer
            )
        );
        portfolioManager.multicall(cd, fac);
        vm.stopPrank();
    }

    function _borrow(uint256 amount) internal {
        // HydrexCollateralFacet exposes increaseTotalDebt; call it via multicall
        // so the PortfolioManager-only modifier on the underlying library passes.
        vm.startPrank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(HydrexCollateralFacet.increaseTotalDebt.selector, amount)
        );
        portfolioManager.multicall(cd, fac);
        vm.stopPrank();
    }

    function _buy(uint256 tokenId) internal {
        uint256 nonce = portfolioMarketplace.getListing(tokenId).nonce;
        vm.startPrank(buyer);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(FortyAcresMarketplaceFacet.buyFortyAcresListing.selector, tokenId, nonce);
        address[] memory fac = new address[](1);
        fac[0] = address(walletFactory);
        portfolioManager.multicall(cd, fac);
        vm.stopPrank();
    }

    // ────────────────────────────────────────────────────────────
    // 1) Happy path, no debt
    // ────────────────────────────────────────────────────────────

    function test_purchaseListing_noDebt_happyPath() public {
        uint256 lockAmount = 5e18;
        uint256 tokenId = _seedRollingLock(lockAmount);
        address buyerWallet = walletFactory.portfolioOf(buyer);

        _makeListing(tokenId, LISTING_PRICE, 0, address(0));

        uint256 sellerBalBefore = usdc.balanceOf(user);
        uint256 feeBalBefore = usdc.balanceOf(feeRecipient);
        uint256 buyerWalletBalBefore = usdc.balanceOf(buyerWallet);
        uint256 lockedBefore = HydrexCollateralFacet(portfolioAccount).getTotalLockedCollateral();

        _buy(tokenId);

        uint256 expectedFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        uint256 expectedSeller = LISTING_PRICE - expectedFee;

        assertEq(IVotingEscrow(address(ve)).ownerOf(tokenId), buyerWallet, "NFT to buyer wallet");
        assertEq(usdc.balanceOf(user) - sellerBalBefore, expectedSeller, "seller net = price - fee");
        assertEq(usdc.balanceOf(feeRecipient) - feeBalBefore, expectedFee, "fee recipient = protocolFee");
        assertEq(buyerWalletBalBefore - usdc.balanceOf(buyerWallet), LISTING_PRICE, "buyer paid full price");

        assertFalse(IMarketplaceFacet(portfolioAccount).hasSaleAuthorization(tokenId), "local auth cleared");
        assertEq(portfolioMarketplace.getListing(tokenId).owner, address(0), "central listing cleared");

        // Collateral accounting must drop by exactly the lock amount.
        uint256 lockedAfter = HydrexCollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertEq(lockedBefore - lockedAfter, lockAmount, "locked collateral decreased by lock amount");
    }

    // ────────────────────────────────────────────────────────────
    // 2) Happy path with debt: single NFT => all debt paid down
    // ────────────────────────────────────────────────────────────

    function test_purchaseListing_withDebt_singleNftClearsDebt() public {
        uint256 tokenId = _seedRollingLock(1000e18);
        address buyerWallet = walletFactory.portfolioOf(buyer);

        // Borrow small amount; listing at LISTING_PRICE easily covers it.
        _borrow(100e6);
        uint256 debtBefore = HydrexCollateralFacet(portfolioAccount).getTotalDebt();
        assertGt(debtBefore, 0, "must have debt");

        _makeListing(tokenId, LISTING_PRICE, 0, address(0));

        uint256 sellerBalBefore = usdc.balanceOf(user);
        uint256 feeBalBefore = usdc.balanceOf(feeRecipient);

        _buy(tokenId);

        // Single NFT: required payment == total debt, so debt must hit zero.
        assertEq(HydrexCollateralFacet(portfolioAccount).getTotalDebt(), 0, "debt fully cleared");
        assertEq(IVotingEscrow(address(ve)).ownerOf(tokenId), buyerWallet, "NFT to buyer wallet");

        uint256 expectedFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        // Net payment = price - fee; debt paydown = debtBefore; remainder to seller.
        uint256 expectedSellerNet = LISTING_PRICE - expectedFee - debtBefore;
        assertEq(usdc.balanceOf(user) - sellerBalBefore, expectedSellerNet, "seller receives net minus debt");
        assertEq(usdc.balanceOf(feeRecipient) - feeBalBefore, expectedFee, "fee recipient = protocolFee");
    }

    // ────────────────────────────────────────────────────────────
    // 3) makeListing reverts when net price < required debt paydown
    // ────────────────────────────────────────────────────────────

    function test_makeListing_revertsWhenPriceTooLowForDebt() public {
        // Lock large enough to support a 500 USDC borrow under the harness's
        // rewardsRate/multiplier; 1000e18 only supports ~148 USDC.
        uint256 tokenId = _seedRollingLock(5000e18);
        _borrow(500e6);
        uint256 totalDebt = HydrexCollateralFacet(portfolioAccount).getTotalDebt();
        assertGt(totalDebt, 0);

        // price == debt => net = debt * 0.99 < debt; identical to Velo test case.
        vm.startPrank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(
                BaseMarketplaceFacet.makeListing.selector,
                tokenId, totalDebt, address(usdc), uint256(0), address(0)
            )
        );
        vm.expectRevert(bytes("Price too low to cover debt after fees"));
        portfolioManager.multicall(cd, fac);
        vm.stopPrank();

        assertFalse(IMarketplaceFacet(portfolioAccount).hasSaleAuthorization(tokenId), "no auth created");
        assertEq(IVotingEscrow(address(ve)).ownerOf(tokenId), portfolioAccount, "NFT stays with seller");
    }

    // ────────────────────────────────────────────────────────────
    // 4) cancelListing clears local + centralized state
    // ────────────────────────────────────────────────────────────

    function test_cancelListing_clearsLocalAndCentralState() public {
        uint256 tokenId = _seedRollingLock(5e18);
        _makeListing(tokenId, LISTING_PRICE, 0, address(0));
        assertTrue(IMarketplaceFacet(portfolioAccount).hasSaleAuthorization(tokenId), "auth set");
        assertEq(portfolioMarketplace.getListing(tokenId).owner, portfolioAccount, "central listing set");

        vm.startPrank(user);
        (bytes[] memory cd, address[] memory fac) = _mc(
            abi.encodeWithSelector(BaseMarketplaceFacet.cancelListing.selector, tokenId)
        );
        portfolioManager.multicall(cd, fac);
        vm.stopPrank();

        assertFalse(IMarketplaceFacet(portfolioAccount).hasSaleAuthorization(tokenId), "auth cleared");
        assertEq(portfolioMarketplace.getListing(tokenId).owner, address(0), "central listing cleared");
    }

    // ────────────────────────────────────────────────────────────
    // 5) Restricted buyer: unauthorized buyer reverts with BuyerNotAllowed
    // ────────────────────────────────────────────────────────────

    function test_purchaseListing_revertsWhenBuyerNotAllowed() public {
        uint256 tokenId = _seedRollingLock(5e18);
        // Restrict listing to a different EOA than `buyer`.
        address allowedEoa = address(0xA110E0);
        _makeListing(tokenId, LISTING_PRICE, 0, allowedEoa);

        uint256 nonce = portfolioMarketplace.getListing(tokenId).nonce;

        vm.startPrank(buyer);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(FortyAcresMarketplaceFacet.buyFortyAcresListing.selector, tokenId, nonce);
        address[] memory fac = new address[](1);
        fac[0] = address(walletFactory);
        vm.expectRevert(PortfolioMarketplace.BuyerNotAllowed.selector);
        portfolioManager.multicall(cd, fac);
        vm.stopPrank();

        // NFT still with seller.
        assertEq(IVotingEscrow(address(ve)).ownerOf(tokenId), portfolioAccount, "NFT stays with seller");
    }

    // ────────────────────────────────────────────────────────────
    // 6) isListingPurchasable flips to false after debt grows past safe paydown
    // ────────────────────────────────────────────────────────────

    function test_isListingPurchasable_falseAfterDebtIncrease() public {
        uint256 tokenId = _seedRollingLock(1000e18);

        // Borrow small amount, list at the minimum price that covers it after fee.
        _borrow(100e6);
        uint256 debtAfterFirstBorrow = HydrexCollateralFacet(portfolioAccount).getTotalDebt();
        // ceil-ish: pick a price where price * (1 - feeBps/10000) >= debt.
        uint256 listingPrice = (debtAfterFirstBorrow * 10100) / 9900;
        _makeListing(tokenId, listingPrice, 0, address(0));

        (bool purchasableBefore,, ) = IMarketplaceFacet(portfolioAccount).isListingPurchasable(tokenId);
        assertTrue(purchasableBefore, "purchasable initially");

        // Push debt up to the cap so net payment can no longer cover required paydown.
        (uint256 maxLoanAvailable, ) = HydrexCollateralFacet(portfolioAccount).getMaxLoan();
        if (maxLoanAvailable > 0) {
            _borrow(maxLoanAvailable);
        }

        (bool purchasableAfter, uint256 requiredPayment, uint256 netPayment) =
            IMarketplaceFacet(portfolioAccount).isListingPurchasable(tokenId);
        assertFalse(purchasableAfter, "no longer purchasable");
        assertGt(requiredPayment, netPayment, "required > net");
    }

    // ────────────────────────────────────────────────────────────
    // buyFortyAcresListingFrom -- allowlisted-marketplace path
    // ────────────────────────────────────────────────────────────

    /// @dev Buy via the 3-arg buyFortyAcresListingFrom against an explicit
    ///      marketplace address, routed through the buyer wallet factory multicall.
    function _buyFrom(uint256 tokenId, address marketplace) internal {
        uint256 nonce = PortfolioMarketplace(marketplace).getListing(tokenId).nonce;
        vm.startPrank(buyer);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListingFrom.selector, tokenId, nonce, marketplace
        );
        address[] memory fac = new address[](1);
        fac[0] = address(walletFactory);
        portfolioManager.multicall(cd, fac);
        vm.stopPrank();
    }

    // CRITICAL (lending-review deviation-1 mitigation): the allowlist gate must
    // run BEFORE any approval/transfer. We assert the revert reason is exactly
    // "Marketplace not allowed" AND that no allowance was granted -- proving the
    // require() short-circuits before _buy's forceApprove.
    function test_buyFortyAcresListingFrom_revertsWhenNotAllowlisted() public {
        uint256 tokenId = _seedRollingLock(5e18);
        address buyerWallet = walletFactory.portfolioOf(buyer);
        _makeListing(tokenId, LISTING_PRICE, 0, address(0));

        // Sanity: the wallet factory config has NOT allowlisted this marketplace.
        assertFalse(
            walletFactoryConfig.isAllowedMarketplace(address(portfolioMarketplace)),
            "precondition: marketplace not allowlisted"
        );

        uint256 nonce = portfolioMarketplace.getListing(tokenId).nonce;
        vm.startPrank(buyer);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListingFrom.selector,
            tokenId, nonce, address(portfolioMarketplace)
        );
        address[] memory fac = new address[](1);
        fac[0] = address(walletFactory);
        vm.expectRevert(bytes("Marketplace not allowed"));
        portfolioManager.multicall(cd, fac);
        vm.stopPrank();

        // The revert happened before any forceApprove: residual allowance is 0.
        assertEq(
            usdc.allowance(buyerWallet, address(portfolioMarketplace)),
            0,
            "no approval granted before allowlist gate"
        );
        // NFT untouched, listing still live.
        assertEq(IVotingEscrow(address(ve)).ownerOf(tokenId), portfolioAccount, "NFT stays with seller");
        assertEq(portfolioMarketplace.getListing(tokenId).owner, portfolioAccount, "listing still live");
    }

    // Happy path once allowlisted: mirrors test_purchaseListing_noDebt_happyPath
    // post-conditions and additionally asserts residual allowance is cleared to 0.
    function test_buyFortyAcresListingFrom_happyPathOnceAllowlisted() public {
        uint256 lockAmount = 5e18;
        uint256 tokenId = _seedRollingLock(lockAmount);
        address buyerWallet = walletFactory.portfolioOf(buyer);
        _makeListing(tokenId, LISTING_PRICE, 0, address(0));

        // Allowlist on the WALLET factory's config (the one the facet reads).
        vm.prank(owner_);
        walletFactoryConfig.setAllowedMarketplace(address(portfolioMarketplace), true);

        uint256 sellerBalBefore = usdc.balanceOf(user);
        uint256 feeBalBefore = usdc.balanceOf(feeRecipient);
        uint256 buyerWalletBalBefore = usdc.balanceOf(buyerWallet);

        _buyFrom(tokenId, address(portfolioMarketplace));

        uint256 expectedFee = (LISTING_PRICE * PROTOCOL_FEE_BPS) / 10000;
        uint256 expectedSeller = LISTING_PRICE - expectedFee;

        assertEq(IVotingEscrow(address(ve)).ownerOf(tokenId), buyerWallet, "NFT to buyer wallet");
        assertEq(usdc.balanceOf(user) - sellerBalBefore, expectedSeller, "seller net = price - fee");
        assertEq(usdc.balanceOf(feeRecipient) - feeBalBefore, expectedFee, "fee recipient = protocolFee");
        assertEq(buyerWalletBalBefore - usdc.balanceOf(buyerWallet), LISTING_PRICE, "buyer paid full price");
        assertEq(portfolioMarketplace.getListing(tokenId).owner, address(0), "central listing cleared");

        // Residual approval cleared back to 0 by _buy's trailing forceApprove(0).
        assertEq(
            usdc.allowance(buyerWallet, address(portfolioMarketplace)),
            0,
            "residual allowance cleared after purchase"
        );
    }

    // Toggling the allowlist back off re-blocks the path. Allowlist + buy once,
    // then unset, then attempt a second listing and expect the gate to fire.
    function test_buyFortyAcresListingFrom_toggleOffReblocks() public {
        // First listing: allowlist on, buy succeeds.
        uint256 tokenId1 = _seedRollingLock(5e18);
        address buyerWallet = walletFactory.portfolioOf(buyer);
        _makeListing(tokenId1, LISTING_PRICE, 0, address(0));

        vm.prank(owner_);
        walletFactoryConfig.setAllowedMarketplace(address(portfolioMarketplace), true);

        _buyFrom(tokenId1, address(portfolioMarketplace));
        assertEq(IVotingEscrow(address(ve)).ownerOf(tokenId1), buyerWallet, "first buy succeeded");

        // Toggle off.
        vm.prank(owner_);
        walletFactoryConfig.setAllowedMarketplace(address(portfolioMarketplace), false);
        assertFalse(
            walletFactoryConfig.isAllowedMarketplace(address(portfolioMarketplace)),
            "marketplace de-allowlisted"
        );

        // Second listing: buy must now revert at the gate.
        uint256 tokenId2 = _seedRollingLock(5e18);
        _makeListing(tokenId2, LISTING_PRICE, 0, address(0));

        uint256 nonce = portfolioMarketplace.getListing(tokenId2).nonce;
        vm.startPrank(buyer);
        bytes[] memory cd = new bytes[](1);
        cd[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListingFrom.selector,
            tokenId2, nonce, address(portfolioMarketplace)
        );
        address[] memory fac = new address[](1);
        fac[0] = address(walletFactory);
        vm.expectRevert(bytes("Marketplace not allowed"));
        portfolioManager.multicall(cd, fac);
        vm.stopPrank();

        assertEq(IVotingEscrow(address(ve)).ownerOf(tokenId2), portfolioAccount, "second NFT stays with seller");
    }
}
