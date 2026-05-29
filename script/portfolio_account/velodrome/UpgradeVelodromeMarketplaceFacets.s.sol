// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfigDeploy} from "../DeployPortfolioFactoryConfig.s.sol";

import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {FortyAcresMarketplaceFacet} from "../../../src/facets/account/marketplace/FortyAcresMarketplaceFacet.sol";
import {VexyFacet} from "../../../src/facets/account/marketplace/VexyFacet.sol";

/**
 * @title UpgradeVelodromeMarketplaceFacets
 * @dev Fixes the marketplace facet wiring on BOTH Velodrome (OP) factories:
 *      "velodrome" (relayer, registry 0xfbb7..31E2) and "velodrome-usdc"
 *      (registry 0x8139..2c86). They are separate diamonds with separate
 *      registries (both owned by the same multisig) and are in different states:
 *
 *        - velodrome-usdc: MarketplaceFacet was registered with only 7 of 8
 *          selectors -- isListingPurchasable (0xdbc1787c) was never mapped, so
 *          makeListing reverts on its own this.isListingPurchasable self-call.
 *          FortyAcres / Vexy facets were never deployed.
 *        - velodrome: MarketplaceFacet already carries all 8 selectors, but the
 *          FortyAcres / Vexy facets were never deployed.
 *
 *      Per factory, each facet is touched ONLY if its selector is missing, so the
 *      already-complete MarketplaceFacet on velodrome is left untouched (no churn):
 *        1. MarketplaceFacet -- if isListingPurchasable is unregistered, redeploy
 *           reusing the EXISTING live PortfolioMarketplace + votingEscrow (read off
 *           the registered facet; do NOT deploy a new PortfolioMarketplace) and
 *           replaceFacet with all 8 selectors.
 *        2. FortyAcresMarketplaceFacet -- if buyFortyAcresListing is unregistered,
 *           deploy and register.
 *        3. VexyFacet -- if buyVexyListing is unregistered, deploy and register.
 *           The Vexy marketplace address is a hardcoded immutable in the facet.
 *
 *      Facets are deployed per-factory (they read factory-specific state such as
 *      portfolioFactoryConfig / ownerOf), so each factory gets its own instances.
 *
 *      The FacetRegistry owner is the multisig, so _registerFacet detects the
 *      deployer is not the owner and PRINTS the replaceFacet / registerFacet Safe
 *      calldata rather than executing. The multisig submits the printed calls (To:
 *      the per-factory registry address) to complete each cut.
 *
 *      Run (broadcast deploys the facet bytecode; capture the printed Safe calldata):
 *        forge script script/portfolio_account/velodrome/UpgradeVelodromeMarketplaceFacets.s.sol:UpgradeVelodromeMarketplaceFacets \
 *          --chain-id 10 --rpc-url $OP_RPC_URL --broadcast --verify --via-ir
 */
contract UpgradeVelodromeMarketplaceFacets is PortfolioFactoryConfigDeploy {
    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _upgradeFactory("velodrome");
        _upgradeFactory("velodrome-usdc");
        vm.stopBroadcast();
    }

    function _upgradeFactory(string memory salt) internal {
        PortfolioManager portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);
        PortfolioFactory portfolioFactory =
            PortfolioFactory(portfolioManager.factoryBySalt(keccak256(abi.encodePacked(salt))));
        require(address(portfolioFactory) != address(0), "PortfolioFactory not found");

        FacetRegistry facetRegistry = portfolioFactory.facetRegistry();

        // Existing MarketplaceFacet (makeListing is the anchor selector on both factories).
        address existingFacet = facetRegistry.getFacetForSelector(BaseMarketplaceFacet.makeListing.selector);
        require(existingFacet != address(0), "MarketplaceFacet not registered");

        // Reuse the live PortfolioMarketplace and votingEscrow -- read them off the
        // existing facet so nothing is hardcoded and no live state is orphaned.
        address marketplace = MarketplaceFacet(existingFacet).marketplace();
        address votingEscrow = address(MarketplaceFacet(existingFacet)._votingEscrow());

        console.log("=== Factory salt:", salt);
        console.log("registry:", address(facetRegistry));

        // 1. MarketplaceFacet: only if isListingPurchasable is missing.
        if (facetRegistry.getFacetForSelector(BaseMarketplaceFacet.isListingPurchasable.selector) == address(0)) {
            MarketplaceFacet marketplaceFacet =
                new MarketplaceFacet(address(portfolioFactory), votingEscrow, marketplace);
            bytes4[] memory marketplaceSelectors = new bytes4[](8);
            marketplaceSelectors[0] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
            marketplaceSelectors[1] = BaseMarketplaceFacet.makeListing.selector;
            marketplaceSelectors[2] = BaseMarketplaceFacet.cancelListing.selector;
            marketplaceSelectors[3] = BaseMarketplaceFacet.marketplace.selector;
            marketplaceSelectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
            marketplaceSelectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
            marketplaceSelectors[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
            marketplaceSelectors[7] = BaseMarketplaceFacet.isListingPurchasable.selector;
            _registerFacet(facetRegistry, address(marketplaceFacet), marketplaceSelectors, "MarketplaceFacet");
        } else {
            console.log("MarketplaceFacet already complete (isListingPurchasable registered); skipping");
        }

        // 2. FortyAcresMarketplaceFacet: only if buyFortyAcresListing is missing.
        if (facetRegistry.getFacetForSelector(FortyAcresMarketplaceFacet.buyFortyAcresListing.selector) == address(0)) {
            FortyAcresMarketplaceFacet fortyAcresFacet =
                new FortyAcresMarketplaceFacet(address(portfolioFactory), votingEscrow, marketplace);
            bytes4[] memory fortyAcresSelectors = new bytes4[](1);
            fortyAcresSelectors[0] = FortyAcresMarketplaceFacet.buyFortyAcresListing.selector;
            _registerFacet(facetRegistry, address(fortyAcresFacet), fortyAcresSelectors, "FortyAcresMarketplaceFacet");
        } else {
            console.log("FortyAcresMarketplaceFacet already registered; skipping");
        }

        // 3. VexyFacet: only if buyVexyListing is missing. The Vexy marketplace
        //    address is a hardcoded immutable in the facet, so it only needs
        //    portfolioFactory + votingEscrow.
        if (facetRegistry.getFacetForSelector(VexyFacet.buyVexyListing.selector) == address(0)) {
            VexyFacet vexyFacet = new VexyFacet(address(portfolioFactory), votingEscrow);
            bytes4[] memory vexySelectors = new bytes4[](1);
            vexySelectors[0] = VexyFacet.buyVexyListing.selector;
            _registerFacet(facetRegistry, address(vexyFacet), vexySelectors, "VexyFacet");
        } else {
            console.log("VexyFacet already registered; skipping");
        }
    }
}
