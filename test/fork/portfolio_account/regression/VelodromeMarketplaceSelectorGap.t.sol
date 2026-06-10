// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";

import {BaseMarketplaceFacet} from "../../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";

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
 *      Run: FOUNDRY_PROFILE=fork forge test \
 *        --match-path test/fork/portfolio_account/regression/VelodromeMarketplaceSelectorGap.t.sol -vvv
 */
contract VelodromeMarketplaceSelectorGap is Test {
    // ─── Live Velodrome/OP addresses (verified on-chain) ─────────────
    address public constant PORTFOLIO_MANAGER = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;
    address public constant FACET_REGISTRY = 0x8139B24596dC0BeE2F7A66D5a0D519C16C962c86;
    address public constant PORTFOLIO_FACTORY = 0x8A71e4BaB42DDC3d996FA4b4780919567e367924;
    address public constant EXISTING_MARKETPLACE_FACET = 0xd5f0dFeB2F10559352CC5CA11b3E54aB08505EAC;

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
