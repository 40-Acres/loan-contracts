// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";

import {MarketplaceFacet} from "../../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {FortyAcresMarketplaceFacet} from "../../../../src/facets/account/marketplace/FortyAcresMarketplaceFacet.sol";
import {VexyFacet} from "../../../../src/facets/account/marketplace/VexyFacet.sol";

import {
    DeployMarketplaceFacet,
    DeployFortyAcresMarketplaceFacet,
    DeployVexyFacet
} from "../../../../script/portfolio_account/facets/DeployMarketplaceFacets.s.sol";

/**
 * @dev Test-local wrappers that expose the deploy scripts' internal-pure
 *      selector lists. By sourcing the expected selectors from the same
 *      getSelectorsForFacet() the deploy/upgrade scripts use, the test
 *      cannot drift from the registration source of truth: if someone
 *      changes the script's selector set, this test moves with it.
 */
contract MarketplaceSelectorSource is DeployMarketplaceFacet {
    function selectors() external pure returns (bytes4[] memory) {
        return getSelectorsForFacet();
    }
}

contract FortyAcresSelectorSource is DeployFortyAcresMarketplaceFacet {
    function selectors() external pure returns (bytes4[] memory) {
        return getSelectorsForFacet();
    }
}

contract VexySelectorSource is DeployVexyFacet {
    function selectors() external pure returns (bytes4[] memory) {
        return getSelectorsForFacet();
    }
}

/**
 * @title VelodromeMarketplaceSelectorGap
 * @dev Fork guard against the marketplace facet selector-registration gap on the
 *      live Velodrome/Optimism diamond.
 *
 *      Ground truth (verified on-chain): the live MarketplaceFacet
 *      (0xaDe29De58d7C546D2c90411dF1fd583F1808A60E) was registered with 7 of its 8
 *      selectors -- isListingPurchasable (0xdbc1787c) was never mapped, so makeListing
 *      reverts on its own self-call. FortyAcresMarketplaceFacet (buyFortyAcresListing)
 *      and VexyFacet (buyVexyListing) were never deployed/registered on OP at all.
 *
 *      This test asserts that EVERY selector the deploy/upgrade scripts register for
 *      these three facets resolves to a non-zero, code-bearing facet on the LIVE
 *      OP FacetRegistry.
 *
 *      Pre-remediation: testLive_VelodromeMarketplaceSelectorsAllRegistered FAILS on
 *      isListingPurchasable / buyFortyAcresListing / buyVexyListing (each == address(0)).
 *      Post-remediation (multisig submits the replaceFacet + 2 registerFacet calls
 *      printed by UpgradeVelodromeMarketplaceFacets): it PASSES.
 *
 *      The companion test testLive_RegistrationFix_ClosesTheGap proves the fix mechanics
 *      independently of the multisig timeline: it pranks the live registry owner, applies
 *      the exact same cut the upgrade script emits (sourced from the deploy-script
 *      selector lists), and shows every selector then resolves non-zero.
 *
 *      Run: FOUNDRY_PROFILE=fork forge test \
 *        --match-path test/fork/portfolio_account/regression/VelodromeMarketplaceSelectorGap.t.sol -vvv
 */
contract VelodromeMarketplaceSelectorGap is Test {
    // ─── Live Velodrome/OP addresses (verified on-chain) ─────────────
    address public constant PORTFOLIO_MANAGER = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;
    address public constant FACET_REGISTRY = 0x8139B24596dC0BeE2F7A66D5a0D519C16C962c86;
    address public constant PORTFOLIO_FACTORY = 0x8A71e4BaB42DDC3d996FA4b4780919567e367924;
    address public constant EXISTING_MARKETPLACE_FACET = 0xaDe29De58d7C546D2c90411dF1fd583F1808A60E;

    bytes32 public constant VELODROME_SALT = keccak256(abi.encodePacked("velodrome-usdc"));

    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;

    MarketplaceSelectorSource public marketplaceSelectors;
    FortyAcresSelectorSource public fortyAcresSelectors;
    VexySelectorSource public vexySelectors;

    function setUp() public {
        vm.createSelectFork(vm.envString("OP_RPC_URL"));

        portfolioManager = PortfolioManager(PORTFOLIO_MANAGER);
        portfolioFactory = PortfolioFactory(PORTFOLIO_FACTORY);
        facetRegistry = FacetRegistry(FACET_REGISTRY);

        marketplaceSelectors = new MarketplaceSelectorSource();
        fortyAcresSelectors = new FortyAcresSelectorSource();
        vexySelectors = new VexySelectorSource();
    }

    // ─── Sanity: fork pinned to the right live graph ─────────────────

    function testLive_ForkAddressesAreConsistent() public view {
        // factoryBySalt(velodrome-usdc) must resolve to the known PortfolioFactory.
        assertEq(
            portfolioManager.factoryBySalt(VELODROME_SALT),
            PORTFOLIO_FACTORY,
            "factoryBySalt(velodrome-usdc) should match known PortfolioFactory"
        );
        // The factory's registry must be the known FacetRegistry.
        assertEq(
            address(portfolioFactory.facetRegistry()),
            FACET_REGISTRY,
            "PortfolioFactory.facetRegistry should match known FacetRegistry"
        );
        // The known MarketplaceFacet must currently hold makeListing (anchor selector).
        assertEq(
            facetRegistry.getFacetForSelector(BaseMarketplaceFacet.makeListing.selector),
            EXISTING_MARKETPLACE_FACET,
            "makeListing should route to the known live MarketplaceFacet"
        );
    }

    // ─── PRIMARY GUARD: every registered selector resolves non-zero ──

    /**
     * @dev Fails today on the three unregistered selectors; passes once the
     *      multisig executes the registration. This is the canonical
     *      selector-gap guard and reads only LIVE registry state.
     */
    function testLive_VelodromeMarketplaceSelectorsAllRegistered() public view {
        bytes4[] memory mSel = marketplaceSelectors.selectors();
        bytes4[] memory fSel = fortyAcresSelectors.selectors();
        bytes4[] memory vSel = vexySelectors.selectors();

        // MarketplaceFacet: all 8 selectors (includes isListingPurchasable, the gap).
        for (uint256 i = 0; i < mSel.length; i++) {
            _assertSelectorResolves(mSel[i], "MarketplaceFacet");
        }
        // FortyAcresMarketplaceFacet: buyFortyAcresListing (never registered on OP).
        for (uint256 i = 0; i < fSel.length; i++) {
            _assertSelectorResolves(fSel[i], "FortyAcresMarketplaceFacet");
        }
        // VexyFacet: buyVexyListing (never registered on OP).
        for (uint256 i = 0; i < vSel.length; i++) {
            _assertSelectorResolves(vSel[i], "VexyFacet");
        }
    }

    // ─── Fix mechanics: apply the cut, then re-check all selectors ───

    /**
     * @dev Proves the remediation closes the gap, independent of the multisig
     *      timeline. Pranks the live FacetRegistry owner and applies the EXACT
     *      cut UpgradeVelodromeMarketplaceFacets emits:
     *        1. replaceFacet(existing MarketplaceFacet -> fresh, 8 selectors)
     *        2. registerFacet(FortyAcresMarketplaceFacet, buyFortyAcresListing)
     *        3. registerFacet(VexyFacet, buyVexyListing)
     *      Reuses the live PortfolioMarketplace + votingEscrow read off the
     *      existing facet, exactly like the script.
     */
    function testLive_RegistrationFix_ClosesTheGap() public {
        // Read live marketplace + votingEscrow off the existing facet (script step).
        address marketplace = MarketplaceFacet(EXISTING_MARKETPLACE_FACET).marketplace();
        address votingEscrow = address(MarketplaceFacet(EXISTING_MARKETPLACE_FACET)._votingEscrow());
        assertTrue(marketplace != address(0), "live marketplace should be non-zero");
        assertTrue(votingEscrow != address(0), "live votingEscrow should be non-zero");

        address registryOwner = facetRegistry.owner();

        // 1. Replace MarketplaceFacet with a fresh deploy carrying all 8 selectors.
        MarketplaceFacet newMarketplaceFacet =
            new MarketplaceFacet(PORTFOLIO_FACTORY, votingEscrow, marketplace);
        bytes4[] memory mSel = marketplaceSelectors.selectors();
        vm.prank(registryOwner);
        facetRegistry.replaceFacet(
            EXISTING_MARKETPLACE_FACET, address(newMarketplaceFacet), mSel, "MarketplaceFacet"
        );

        // 2. Register FortyAcresMarketplaceFacet.
        FortyAcresMarketplaceFacet fortyAcresFacet =
            new FortyAcresMarketplaceFacet(PORTFOLIO_FACTORY, votingEscrow, marketplace);
        bytes4[] memory fSel = fortyAcresSelectors.selectors();
        vm.prank(registryOwner);
        facetRegistry.registerFacet(address(fortyAcresFacet), fSel, "FortyAcresMarketplaceFacet");

        // 3. Register VexyFacet (Vexy marketplace is a hardcoded immutable in the facet).
        VexyFacet vexyFacet = new VexyFacet(PORTFOLIO_FACTORY, votingEscrow);
        bytes4[] memory vSel = vexySelectors.selectors();
        vm.prank(registryOwner);
        facetRegistry.registerFacet(address(vexyFacet), vSel, "VexyFacet");

        // ── Post-conditions: every selector now resolves to the right facet ──
        for (uint256 i = 0; i < mSel.length; i++) {
            assertEq(
                facetRegistry.getFacetForSelector(mSel[i]),
                address(newMarketplaceFacet),
                "MarketplaceFacet selector should route to fresh facet after replace"
            );
        }
        assertEq(
            facetRegistry.getFacetForSelector(BaseMarketplaceFacet.isListingPurchasable.selector),
            address(newMarketplaceFacet),
            "isListingPurchasable should resolve after remediation"
        );
        assertEq(
            facetRegistry.getFacetForSelector(FortyAcresMarketplaceFacet.buyFortyAcresListing.selector),
            address(fortyAcresFacet),
            "buyFortyAcresListing should resolve after remediation"
        );
        assertEq(
            facetRegistry.getFacetForSelector(VexyFacet.buyVexyListing.selector),
            address(vexyFacet),
            "buyVexyListing should resolve after remediation"
        );

        // And the full primary-guard invariant holds.
        for (uint256 i = 0; i < fSel.length; i++) {
            _assertSelectorResolves(fSel[i], "FortyAcresMarketplaceFacet");
        }
        for (uint256 i = 0; i < vSel.length; i++) {
            _assertSelectorResolves(vSel[i], "VexyFacet");
        }
    }

    // ─── Internal helpers ────────────────────────────────────────────

    function _assertSelectorResolves(bytes4 selector, string memory facetName) internal view {
        address facet = facetRegistry.getFacetForSelector(selector);
        assertTrue(
            facet != address(0),
            string.concat(
                facetName,
                " selector ",
                vm.toString(selector),
                " is not registered (resolves to address(0))"
            )
        );
        assertTrue(
            facet.code.length > 0,
            string.concat(facetName, " selector ", vm.toString(selector), " resolves to a codeless facet")
        );
        assertTrue(
            facetRegistry.registeredFacets(facet),
            string.concat(facetName, " selector ", vm.toString(selector), " facet not marked registered")
        );
    }
}
