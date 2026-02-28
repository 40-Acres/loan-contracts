// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

// Core accounts
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {FortyAcresPortfolioAccount} from "../../../src/accounts/FortyAcresPortfolioAccount.sol";

// Config
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";

// Wallet facet
import {WalletFacet} from "../../../src/facets/account/wallet/WalletFacet.sol";

// Marketplace facets
import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {FortyAcresMarketplaceFacet} from "../../../src/facets/account/marketplace/FortyAcresMarketplaceFacet.sol";
import {OpenXFacet} from "../../../src/facets/account/marketplace/OpenXFacet.sol";
import {VexyFacet} from "../../../src/facets/account/marketplace/VexyFacet.sol";
import {PortfolioMarketplace} from "../../../src/facets/marketplace/PortfolioMarketplace.sol";

// Collateral/Lending selectors (to verify they're NOT registered)
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";

// Proxy
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title WalletDeployValidation
 * @dev Tests that the wallet factory deployment is structurally correct:
 *      - Only wallet + marketplace facets registered (no collateral, lending, debt)
 *      - enforceCollateralRequirements always returns true
 *      - Correct selector routing
 */
contract WalletDeployValidation is Test {
    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    PortfolioManager public portfolioManager;
    PortfolioFactory public walletFactory;
    FacetRegistry public facetRegistry;

    PortfolioAccountConfig public portfolioAccountConfig;
    SwapConfig public swapConfig;
    PortfolioMarketplace public portfolioMarketplace;

    WalletFacet public walletFacet;
    MarketplaceFacet public marketplaceFacet;
    FortyAcresMarketplaceFacet public fortyAcresFacet;
    OpenXFacet public openXFacet;
    VexyFacet public vexyFacet;

    address public user = address(0x40ac2e);
    address public walletPortfolio;

    function setUp() public {
        vm.mockCall(USDC, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.mockCall(USDC, abi.encodeWithSignature("approve(address,uint256)"), abi.encode(true));

        vm.startPrank(DEPLOYER);

        // Deploy core
        portfolioManager = new PortfolioManager(DEPLOYER);
        (walletFactory, facetRegistry) = portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("wallet")))
        );

        // Deploy configs
        PortfolioAccountConfig configImpl = new PortfolioAccountConfig();
        portfolioAccountConfig = PortfolioAccountConfig(
            address(new ERC1967Proxy(address(configImpl), abi.encodeCall(PortfolioAccountConfig.initialize, (DEPLOYER))))
        );

        SwapConfig swapConfigImpl = new SwapConfig();
        swapConfig = SwapConfig(
            address(new ERC1967Proxy(address(swapConfigImpl), abi.encodeCall(SwapConfig.initialize, (DEPLOYER))))
        );

        // Deploy marketplace
        portfolioMarketplace = new PortfolioMarketplace(
            address(portfolioManager), VOTING_ESCROW, 100, DEPLOYER
        );

        // Deploy and register facets (mirrors DeployWallet.s.sol)
        _deployAndRegisterFacets();

        vm.stopPrank();

        walletPortfolio = walletFactory.createAccount(user);
    }

    function _deployAndRegisterFacets() internal {
        // 1. WalletFacet (6 selectors)
        walletFacet = new WalletFacet(
            address(walletFactory), address(portfolioAccountConfig), address(swapConfig)
        );
        bytes4[] memory walletSel = new bytes4[](6);
        walletSel[0] = WalletFacet.transferERC20.selector;
        walletSel[1] = WalletFacet.transferNFT.selector;
        walletSel[2] = WalletFacet.receiveERC20.selector;
        walletSel[3] = WalletFacet.swap.selector;
        walletSel[4] = WalletFacet.onERC721Received.selector;
        walletSel[5] = WalletFacet.enforceCollateralRequirements.selector;
        facetRegistry.registerFacet(address(walletFacet), walletSel, "WalletFacet");

        // 2. MarketplaceFacet (7 selectors)
        marketplaceFacet = new MarketplaceFacet(
            address(walletFactory), address(portfolioAccountConfig), VOTING_ESCROW, address(portfolioMarketplace)
        );
        bytes4[] memory marketplaceSel = new bytes4[](7);
        marketplaceSel[0] = BaseMarketplaceFacet.makeListing.selector;
        marketplaceSel[1] = BaseMarketplaceFacet.cancelListing.selector;
        marketplaceSel[2] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        marketplaceSel[3] = BaseMarketplaceFacet.marketplace.selector;
        marketplaceSel[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        marketplaceSel[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        marketplaceSel[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
        facetRegistry.registerFacet(address(marketplaceFacet), marketplaceSel, "MarketplaceFacet");

        // 3. FortyAcresMarketplaceFacet (1 selector)
        fortyAcresFacet = new FortyAcresMarketplaceFacet(
            address(walletFactory), address(portfolioAccountConfig), VOTING_ESCROW, address(portfolioMarketplace)
        );
        bytes4[] memory fortyAcresSel = new bytes4[](1);
        fortyAcresSel[0] = FortyAcresMarketplaceFacet.buyFortyAcresListing.selector;
        facetRegistry.registerFacet(address(fortyAcresFacet), fortyAcresSel, "FortyAcresMarketplaceFacet");

        // 4. OpenXFacet (1 selector)
        openXFacet = new OpenXFacet(
            address(walletFactory), address(portfolioAccountConfig), VOTING_ESCROW
        );
        bytes4[] memory openXSel = new bytes4[](1);
        openXSel[0] = OpenXFacet.buyOpenXListing.selector;
        facetRegistry.registerFacet(address(openXFacet), openXSel, "OpenXFacet");

        // 5. VexyFacet (1 selector)
        vexyFacet = new VexyFacet(
            address(walletFactory), address(portfolioAccountConfig), VOTING_ESCROW
        );
        bytes4[] memory vexySel = new bytes4[](1);
        vexySel[0] = VexyFacet.buyVexyListing.selector;
        facetRegistry.registerFacet(address(vexyFacet), vexySel, "VexyFacet");
    }

    // ─── Core structure ────────────────────────────────────────────────

    function testCoreContractsDeployed() public view {
        assertTrue(address(portfolioManager) != address(0));
        assertTrue(address(walletFactory) != address(0));
        assertTrue(address(facetRegistry) != address(0));
    }

    function testFactoryRegistered() public view {
        assertTrue(portfolioManager.isRegisteredFactory(address(walletFactory)));
    }

    function testFactoryBySalt() public view {
        bytes32 salt = bytes32(keccak256(abi.encodePacked("wallet")));
        assertEq(portfolioManager.factoryBySalt(salt), address(walletFactory));
    }

    function testFactoryRegistryLinkage() public view {
        assertEq(address(walletFactory.facetRegistry()), address(facetRegistry));
    }

    function testFactoryManagerLinkage() public view {
        assertEq(address(walletFactory.portfolioManager()), address(portfolioManager));
    }

    // ─── Facet count ───────────────────────────────────────────────────

    function testFacetCount() public view {
        address[] memory facets = facetRegistry.getAllFacets();
        assertEq(facets.length, 5, "Wallet factory should have exactly 5 facets");
    }

    // ─── Per-facet registration ────────────────────────────────────────

    function testWalletFacetRegistration() public view {
        _assertFacetRegistered(address(walletFacet), "WalletFacet", 6);
    }

    function testMarketplaceFacetRegistration() public view {
        _assertFacetRegistered(address(marketplaceFacet), "MarketplaceFacet", 7);
    }

    function testFortyAcresMarketplaceFacetRegistration() public view {
        _assertFacetRegistered(address(fortyAcresFacet), "FortyAcresMarketplaceFacet", 1);
    }

    function testOpenXFacetRegistration() public view {
        _assertFacetRegistered(address(openXFacet), "OpenXFacet", 1);
    }

    function testVexyFacetRegistration() public view {
        _assertFacetRegistered(address(vexyFacet), "VexyFacet", 1);
    }

    // ─── Selector routing ──────────────────────────────────────────────

    function testWalletSelectorsRouteCorrectly() public view {
        assertEq(facetRegistry.getFacetForSelector(WalletFacet.transferERC20.selector), address(walletFacet));
        assertEq(facetRegistry.getFacetForSelector(WalletFacet.transferNFT.selector), address(walletFacet));
        assertEq(facetRegistry.getFacetForSelector(WalletFacet.receiveERC20.selector), address(walletFacet));
        assertEq(facetRegistry.getFacetForSelector(WalletFacet.swap.selector), address(walletFacet));
        assertEq(facetRegistry.getFacetForSelector(WalletFacet.onERC721Received.selector), address(walletFacet));
        assertEq(facetRegistry.getFacetForSelector(WalletFacet.enforceCollateralRequirements.selector), address(walletFacet));
    }

    function testMarketplaceSelectorsRouteCorrectly() public view {
        assertEq(facetRegistry.getFacetForSelector(BaseMarketplaceFacet.makeListing.selector), address(marketplaceFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseMarketplaceFacet.cancelListing.selector), address(marketplaceFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseMarketplaceFacet.receiveSaleProceeds.selector), address(marketplaceFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseMarketplaceFacet.marketplace.selector), address(marketplaceFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseMarketplaceFacet.getSaleAuthorization.selector), address(marketplaceFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseMarketplaceFacet.hasSaleAuthorization.selector), address(marketplaceFacet));
        assertEq(facetRegistry.getFacetForSelector(BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector), address(marketplaceFacet));
    }

    function testBuyerFacetSelectorsRouteCorrectly() public view {
        assertEq(facetRegistry.getFacetForSelector(FortyAcresMarketplaceFacet.buyFortyAcresListing.selector), address(fortyAcresFacet));
        assertEq(facetRegistry.getFacetForSelector(OpenXFacet.buyOpenXListing.selector), address(openXFacet));
        assertEq(facetRegistry.getFacetForSelector(VexyFacet.buyVexyListing.selector), address(vexyFacet));
    }

    // ─── No collateral/lending/debt facets ─────────────────────────────

    function testNoCollateralFacetRegistered() public view {
        assertEq(
            facetRegistry.getFacetForSelector(BaseCollateralFacet.addCollateral.selector),
            address(0),
            "Wallet factory must NOT have addCollateral"
        );
        assertEq(
            facetRegistry.getFacetForSelector(BaseCollateralFacet.getTotalLockedCollateral.selector),
            address(0),
            "Wallet factory must NOT have getTotalLockedCollateral"
        );
        assertEq(
            facetRegistry.getFacetForSelector(BaseCollateralFacet.getTotalDebt.selector),
            address(0),
            "Wallet factory must NOT have getTotalDebt"
        );
        assertEq(
            facetRegistry.getFacetForSelector(BaseCollateralFacet.removeCollateral.selector),
            address(0),
            "Wallet factory must NOT have removeCollateral"
        );
        assertEq(
            facetRegistry.getFacetForSelector(BaseCollateralFacet.getMaxLoan.selector),
            address(0),
            "Wallet factory must NOT have getMaxLoan"
        );
    }

    function testNoLendingFacetRegistered() public view {
        assertEq(
            facetRegistry.getFacetForSelector(BaseLendingFacet.borrow.selector),
            address(0),
            "Wallet factory must NOT have borrow"
        );
        assertEq(
            facetRegistry.getFacetForSelector(BaseLendingFacet.pay.selector),
            address(0),
            "Wallet factory must NOT have pay"
        );
        assertEq(
            facetRegistry.getFacetForSelector(BaseLendingFacet.borrowTo.selector),
            address(0),
            "Wallet factory must NOT have borrowTo"
        );
    }

    // ─── enforceCollateralRequirements always passes ───────────────────

    function testEnforceCollateralRequirementsAlwaysTrue() public view {
        // WalletFacet.enforceCollateralRequirements() is a pure function returning true
        // Call it via the diamond to verify it routes correctly and returns true
        bool result = WalletFacet(walletPortfolio).enforceCollateralRequirements();
        assertTrue(result, "Wallet enforceCollateralRequirements must always return true");
    }

    // ─── Portfolio account ─────────────────────────────────────────────

    function testPortfolioAccountCreated() public view {
        assertTrue(walletPortfolio != address(0));
    }

    function testPortfolioAccountRegistered() public view {
        assertTrue(portfolioManager.isPortfolioRegistered(walletPortfolio));
    }

    function testPortfolioAccountOwner() public view {
        assertEq(walletFactory.ownerOf(walletPortfolio), user);
    }

    function testPortfolioAccountRegistry() public view {
        FortyAcresPortfolioAccount account = FortyAcresPortfolioAccount(payable(walletPortfolio));
        assertEq(address(account.facetRegistry()), address(facetRegistry));
    }

    function testPortfolioLookupByOwner() public view {
        assertEq(walletFactory.portfolioOf(user), walletPortfolio);
    }

    // ─── Registry version ──────────────────────────────────────────────

    function testRegistryVersion() public view {
        // 1 (initial) + 5 (facet registrations) = 6
        assertEq(facetRegistry.getVersion(), 6, "Registry version should be 6 after 5 registrations");
    }

    // ─── Internal helpers ──────────────────────────────────────────────

    function _assertFacetRegistered(address facet, string memory expectedName, uint256 expectedSelectorCount) internal view {
        assertTrue(facetRegistry.isFacetRegistered(facet), string.concat(expectedName, " should be registered"));

        bytes4[] memory selectors = facetRegistry.getSelectorsForFacet(facet);
        assertEq(selectors.length, expectedSelectorCount, string.concat(expectedName, " selector count mismatch"));

        string memory actualName = facetRegistry.getFacetName(facet);
        assertEq(actualName, expectedName, string.concat(expectedName, " name mismatch"));

        for (uint256 i = 0; i < selectors.length; i++) {
            assertEq(
                facetRegistry.getFacetForSelector(selectors[i]),
                facet,
                string.concat(expectedName, " selector routing mismatch")
            );
        }
    }
}
