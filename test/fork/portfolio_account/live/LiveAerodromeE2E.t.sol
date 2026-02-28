// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {LiveDeploymentSetup} from "./LiveDeploymentSetup.sol";
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../../src/facets/account/lending/BaseLendingFacet.sol";
import {VotingEscrowFacet} from "../../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {ILoanConfig} from "../../../../src/facets/account/config/ILoanConfig.sol";
import {ILendingPool} from "../../../../src/interfaces/ILendingPool.sol";
import {Loan as LoanV2} from "../../../../src/LoanV2.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {BaseMarketplaceFacet} from "../../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {FortyAcresMarketplaceFacet} from "../../../../src/facets/account/marketplace/FortyAcresMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../../src/facets/marketplace/PortfolioMarketplace.sol";
import {WalletFacet} from "../../../../src/facets/account/wallet/WalletFacet.sol";

/**
 * @title LiveAerodromeE2E
 * @dev Full lifecycle and configuration validation tests against the live Base deployment.
 *      Tests the entire call chain, config consistency, and facet registry integrity.
 *
 *      Run: FORGE_PROFILE=fork forge test --match-path test/fork/portfolio_account/live/LiveAerodromeE2E.t.sol -vvv
 */
contract LiveAerodromeE2E is LiveDeploymentSetup {

    // ─── Full lifecycle ──────────────────────────────────────────────

    function testLive_E2E_FullLifecycle() public {
        // Step 1: Verify collateral from setUp's createLock
        uint256 collateral = ICollateralFacet(portfolioAccount).getTotalLockedCollateral();
        assertGt(collateral, 0, "Should have collateral after createLock");

        (uint256 maxLoan,) = ICollateralFacet(portfolioAccount).getMaxLoan();
        assertGt(maxLoan, 0, "maxLoan should be > 0 with collateral and funded vault");

        // Step 2: Borrow
        uint256 borrowAmount = maxLoan > 1e6 ? 1e6 : maxLoan;
        _borrow(borrowAmount);

        uint256 debtAfterBorrow = ICollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debtAfterBorrow, borrowAmount, "Debt should equal borrow amount");

        // Step 3: Repay
        uint256 totalOwed = debtAfterBorrow + ICollateralFacet(portfolioAccount).getUnpaidFees();
        deal(USDC, user, totalOwed);
        vm.startPrank(user);
        IERC20(USDC).approve(portfolioAccount, totalOwed);
        BaseLendingFacet(portfolioAccount).pay(totalOwed);
        vm.stopPrank();

        uint256 debtAfterPay = ICollateralFacet(portfolioAccount).getTotalDebt();
        assertEq(debtAfterPay, 0, "Debt should be 0 after full repayment");

        // Step 4: Remove collateral (tokenId from setUp's createLock)
        _singleMulticallAsUser(
            abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId)
        );

        assertEq(
            ICollateralFacet(portfolioAccount).getTotalLockedCollateral(),
            0,
            "Collateral should be 0 after removal"
        );

        // veNFT should be back with user
        assertEq(
            IVotingEscrow(VOTING_ESCROW).ownerOf(tokenId),
            user,
            "veNFT should be returned to user"
        );
    }

    // ─── Config discovery validation ─────────────────────────────────

    function testLive_E2E_ConfigDiscovery() public view {
        // All discovered addresses should be non-zero
        assertTrue(address(portfolioManager) != address(0), "portfolioManager non-zero");
        assertTrue(address(portfolioAccountConfig) != address(0), "portfolioAccountConfig non-zero");
        assertTrue(address(portfolioFactory) != address(0), "portfolioFactory non-zero");
        assertTrue(address(facetRegistry) != address(0), "facetRegistry non-zero");
        assertTrue(loanContract != address(0), "loanContract non-zero");
        assertTrue(vault != address(0), "vault non-zero");
        assertTrue(loanConfigAddr != address(0), "loanConfigAddr non-zero");
        assertTrue(votingConfigAddr != address(0), "votingConfigAddr non-zero");
        assertTrue(liveOwner != address(0), "liveOwner non-zero");

        // Cross-reference: config and loan agree on factory
        address configFactory = portfolioAccountConfig.getPortfolioFactory();
        address loanFactory = LoanV2(payable(loanContract)).getPortfolioFactory();
        assertEq(configFactory, loanFactory, "Config and Loan should agree on portfolio factory");
        assertEq(configFactory, address(portfolioFactory), "Config factory should match discovered factory");

        // Config getVault reads through loan — should match direct vault discovery
        address configVault = portfolioAccountConfig.getVault();
        assertEq(configVault, vault, "Config getVault should match discovered vault");

        // Config getDebtToken should be non-zero
        address debtToken = portfolioAccountConfig.getDebtToken();
        assertTrue(debtToken != address(0), "debtToken non-zero");
    }

    // ─── Pay call chain validation ───────────────────────────────────

    function testLive_E2E_PayCallChain() public view {
        // Validates every external call in the pay() → decreaseTotalDebt() → getMaxLoan() chain
        // Mirrors ValidateDeployment._validatePayFlow

        // 1. config.getLoanContract()
        address loanProxy = portfolioAccountConfig.getLoanContract();
        assertTrue(loanProxy != address(0), "getLoanContract non-zero");

        // 2. lendingPool.lendingAsset()
        address lendingAsset = ILendingPool(loanProxy).lendingAsset();
        assertTrue(lendingAsset != address(0), "lendingAsset non-zero");

        // 3. lendingPool.lendingVault()
        address lendingVault = ILendingPool(loanProxy).lendingVault();
        assertTrue(lendingVault != address(0), "lendingVault non-zero");

        // 4. lendingPool.activeAssets() — must not revert
        ILendingPool(loanProxy).activeAssets();

        // 5. IERC4626(vault).asset()
        address underlyingAsset = IERC4626(lendingVault).asset();
        assertTrue(underlyingAsset != address(0), "vault underlying asset non-zero");

        // 6. config.getLoanConfig() → getRewardsRate() / getMultiplier()
        ILoanConfig loanConfig = portfolioAccountConfig.getLoanConfig();
        assertTrue(address(loanConfig) != address(0), "getLoanConfig non-zero");
        loanConfig.getRewardsRate();
        loanConfig.getMultiplier();

        // 7. LoanV2.getPortfolioFactory()
        address loanFactoryAddr = LoanV2(payable(loanProxy)).getPortfolioFactory();
        assertTrue(loanFactoryAddr != address(0), "loan.getPortfolioFactory non-zero");
        assertEq(loanFactoryAddr, address(portfolioFactory), "loan factory matches discovered factory");

        // 8. PortfolioFactory.portfolioManager()
        PortfolioManager factoryManager = portfolioFactory.portfolioManager();
        assertTrue(address(factoryManager) != address(0), "factory.portfolioManager non-zero");
        assertEq(address(factoryManager), address(portfolioManager), "factory manager matches root manager");
    }

    // ─── Factory linkage validation ──────────────────────────────────

    function testLive_E2E_FactoryLinkage() public view {
        // Factory → Manager
        PortfolioManager factoryManager = portfolioFactory.portfolioManager();
        assertEq(
            address(factoryManager),
            LIVE_PORTFOLIO_MANAGER,
            "Factory manager should point to live PortfolioManager"
        );

        // Manager → Factory (registered)
        assertTrue(
            portfolioManager.isRegisteredFactory(address(portfolioFactory)),
            "Factory should be registered in manager"
        );

        // Factory → Registry
        FacetRegistry factoryRegistry = portfolioFactory.facetRegistry();
        assertTrue(address(factoryRegistry) != address(0), "Factory registry should be non-zero");

        // Registry version
        uint256 version = factoryRegistry.getVersion();
        assertGt(version, 0, "Registry version should be > 0");

        // Registry is tracked by manager
        assertTrue(
            portfolioManager.isDeployedFacetRegistry(address(factoryRegistry)),
            "Registry should be tracked by manager"
        );
    }

    // ─── Facet registry integrity ────────────────────────────────────

    function testLive_E2E_FacetRegistryIntegrity() public view {
        // Check that key selectors are mapped to registered facets
        bytes4[] memory expectedSelectors = new bytes4[](10);
        expectedSelectors[0] = BaseCollateralFacet.addCollateral.selector;
        expectedSelectors[1] = BaseCollateralFacet.removeCollateral.selector;
        expectedSelectors[2] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        expectedSelectors[3] = BaseCollateralFacet.getTotalDebt.selector;
        expectedSelectors[4] = BaseCollateralFacet.getMaxLoan.selector;
        expectedSelectors[5] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        expectedSelectors[6] = BaseLendingFacet.borrow.selector;
        expectedSelectors[7] = BaseLendingFacet.pay.selector;
        expectedSelectors[8] = VotingEscrowFacet.createLock.selector;
        expectedSelectors[9] = VotingEscrowFacet.increaseLock.selector;

        for (uint256 i = 0; i < expectedSelectors.length; i++) {
            address facet = facetRegistry.getFacetForSelector(expectedSelectors[i]);
            assertTrue(
                facet != address(0),
                string.concat("Selector at index ", vm.toString(i), " not registered")
            );
            assertTrue(
                facetRegistry.registeredFacets(facet),
                string.concat("Facet for selector at index ", vm.toString(i), " not marked as registered")
            );
            assertTrue(
                facet.code.length > 0,
                string.concat("Facet for selector at index ", vm.toString(i), " has no code")
            );
        }

        // Verify all registered facets have non-empty selectors
        address[] memory allFacets = facetRegistry.getAllFacets();
        assertGt(allFacets.length, 0, "Should have registered facets");

        for (uint256 i = 0; i < allFacets.length; i++) {
            assertTrue(
                facetRegistry.registeredFacets(allFacets[i]),
                "Facet in allFacets should be registered"
            );
            bytes4[] memory selectors = facetRegistry.getSelectorsForFacet(allFacets[i]);
            assertGt(
                selectors.length,
                0,
                string.concat("Facet ", vm.toString(allFacets[i]), " should have selectors")
            );
        }
    }

    // ─── Marketplace: list → wallet buy → deposit as collateral ─────

    /**
     * @dev End-to-end marketplace test against live deployment.
     *
     * Flow:
     * 1. Seller creates a veNFT in their Aerodrome-USDC portfolio
     * 2. Seller lists NFT on the live PortfolioMarketplace
     * 3. Buyer (test user) borrows USDC from Aerodrome portfolio → wallet
     * 4. Buyer's wallet purchases the listing
     * 5. Buyer transfers NFT from wallet → Aerodrome portfolio
     * 6. Buyer adds NFT as collateral
     *
     * Uses the live wallet factory and marketplace — no fresh deployments.
     */
    function testLive_E2E_MarketplaceBuyAndDeposit() public {
        // ── Discover live wallet factory & marketplace ────────────────
        bytes32 walletSalt = keccak256(abi.encodePacked("wallet"));
        address walletFactoryAddr = portfolioManager.factoryBySalt(walletSalt);
        require(walletFactoryAddr != address(0), "Live wallet factory not deployed");
        // Discover marketplace from the seller's portfolio (marketplace() is registered on aerodrome)
        PortfolioMarketplace liveMarketplace = PortfolioMarketplace(
            BaseMarketplaceFacet(portfolioAccount).marketplace()
        );
        require(address(liveMarketplace) != address(0), "Marketplace not discovered");

        // Verify USDC is a whitelisted payment token
        require(liveMarketplace.allowedPaymentTokens(USDC), "USDC not allowed on marketplace");

        // ── Create seller with veNFT collateral ──────────────────────
        address seller = address(uint160(uint256(keccak256("live-marketplace-seller"))));
        deal(AERO, seller, 5000e18);

        // Create seller's aerodrome portfolio + veNFT
        address sellerPortfolio = portfolioFactory.createAccount(seller);
        vm.startPrank(seller);
        IERC20(AERO).approve(sellerPortfolio, 5000e18);
        {
            address[] memory factories = new address[](1);
            factories[0] = address(portfolioFactory);
            bytes[] memory calls = new bytes[](1);
            calls[0] = abi.encodeWithSelector(VotingEscrowFacet.createLock.selector, 5000e18);
            bytes[] memory results = portfolioManager.multicall(calls, factories);
            uint256 sellerTokenId = abi.decode(results[0], (uint256));

            // Verify seller has collateral
            uint256 sellerCollateral = ICollateralFacet(sellerPortfolio).getTotalLockedCollateral();
            assertGt(sellerCollateral, 0, "Seller should have collateral");

            // ── Seller lists NFT on marketplace ──────────────────────
            uint256 listingPrice = 100e6; // 100 USDC

            factories[0] = address(portfolioFactory);
            calls[0] = abi.encodeWithSelector(
                BaseMarketplaceFacet.makeListing.selector,
                sellerTokenId,
                listingPrice,
                USDC,
                0,          // never expires
                address(0)  // no buyer restriction
            );
            portfolioManager.multicall(calls, factories);
            vm.stopPrank();

            // Verify listing exists
            PortfolioMarketplace.Listing memory listing = liveMarketplace.getListing(sellerTokenId);
            assertEq(listing.price, listingPrice, "Listing price should match");
            assertEq(listing.owner, sellerPortfolio, "Listing owner should be seller portfolio");
            uint256 nonce = listing.nonce;

            // ── Buyer: borrow to wallet → buy → transfer → deposit ───
            // Create buyer's wallet portfolio (auto-created by multicall)
            // Borrow enough to cover the listing price + origination fee
            // LoanV2 has 0.8% origination fee: borrowAmount * 9920/10000 >= listingPrice
            uint256 borrowAmount = (listingPrice * 10000) / 9920 + 1;

            vm.startPrank(user);
            {
                address[] memory mFactories = new address[](4);
                mFactories[0] = address(portfolioFactory); // borrowTo from aerodrome
                mFactories[1] = walletFactoryAddr;         // buy from wallet
                mFactories[2] = walletFactoryAddr;         // transfer NFT from wallet
                mFactories[3] = address(portfolioFactory); // add collateral to aerodrome

                bytes[] memory mCalls = new bytes[](4);
                // 1. Borrow USDC to wallet portfolio
                mCalls[0] = abi.encodeWithSelector(
                    BaseLendingFacet.borrowTo.selector,
                    walletFactoryAddr, // factory resolves to buyer's wallet via portfolioOf()
                    borrowAmount
                );
                // 2. Wallet purchases the listing
                mCalls[1] = abi.encodeWithSelector(
                    FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
                    sellerTokenId,
                    nonce
                );
                // 3. Transfer NFT from wallet to aerodrome portfolio
                mCalls[2] = abi.encodeWithSelector(
                    WalletFacet.transferNFT.selector,
                    VOTING_ESCROW,
                    sellerTokenId,
                    portfolioAccount
                );
                // 4. Add NFT as collateral in aerodrome
                mCalls[3] = abi.encodeWithSelector(
                    BaseCollateralFacet.addCollateral.selector,
                    sellerTokenId
                );
                portfolioManager.multicall(mCalls, mFactories);
            }
            vm.stopPrank();

            // ── Verify final state ───────────────────────────────────
            // NFT is in buyer's aerodrome portfolio
            assertEq(
                IVotingEscrow(VOTING_ESCROW).ownerOf(sellerTokenId),
                portfolioAccount,
                "NFT should be in buyer's aerodrome portfolio"
            );

            // NFT is locked as collateral (getLockedCollateral for that tokenId > 0)
            uint256 lockedNew = BaseCollateralFacet(portfolioAccount).getLockedCollateral(sellerTokenId);
            assertGt(lockedNew, 0, "Purchased NFT should be locked as collateral");

            // Original collateral still present
            uint256 lockedOriginal = BaseCollateralFacet(portfolioAccount).getLockedCollateral(tokenId);
            assertGt(lockedOriginal, 0, "Original NFT should still be collateral");

            // Buyer has debt from the borrow
            uint256 buyerDebt = ICollateralFacet(portfolioAccount).getTotalDebt();
            assertGt(buyerDebt, 0, "Buyer should have debt after borrowing");

            // Listing should be cleared
            PortfolioMarketplace.Listing memory clearedListing = liveMarketplace.getListing(sellerTokenId);
            assertEq(clearedListing.owner, address(0), "Listing should be cleared after purchase");

            // Seller's collateral should be removed (NFT was sold)
            assertEq(
                ICollateralFacet(sellerPortfolio).getTotalLockedCollateral(),
                0,
                "Seller should have no collateral after sale"
            );
        }
    }

    // ─── Loan config values ──────────────────────────────────────────

    function testLive_E2E_LoanConfigValues() public view {
        ILoanConfig loanConfig = ILoanConfig(loanConfigAddr);

        uint256 rewardsRate = loanConfig.getRewardsRate();
        assertGt(rewardsRate, 0, "rewardsRate should be > 0");
        assertLe(rewardsRate, 100000, "rewardsRate should be <= 100000 (1000%)");

        uint256 multiplier = loanConfig.getMultiplier();
        assertGt(multiplier, 0, "multiplier should be > 0");
        assertLe(multiplier, 10000, "multiplier should be <= 10000");

        uint256 lenderPremium = loanConfig.getLenderPremium();
        assertLe(lenderPremium, 10000, "lenderPremium should be <= 10000 (100%)");

        uint256 treasuryFee = loanConfig.getTreasuryFee();
        assertLe(treasuryFee, 10000, "treasuryFee should be <= 10000 (100%)");

        uint256 zeroBalanceFee = loanConfig.getZeroBalanceFee();
        assertLe(zeroBalanceFee, 10000, "zeroBalanceFee should be <= 10000 (100%)");

        // Combined fees should not exceed 100%
        assertLe(
            lenderPremium + treasuryFee,
            10000,
            "lenderPremium + treasuryFee should not exceed 100%"
        );
    }
}
