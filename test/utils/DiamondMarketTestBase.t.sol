// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

// Diamond interfaces
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "src/interfaces/IDiamondLoupe.sol";

// Diamond root and facets
import {DiamondHitch} from "src/diamonds/DiamondHitch.sol";
import {DiamondCutFacet} from "src/facets/core/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "src/facets/core/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "src/facets/core/OwnershipFacet.sol";

// Market facets
import {MarketConfigFacet} from "src/facets/market/MarketConfigFacet.sol";
import {MarketViewFacet} from "src/facets/market/MarketViewFacet.sol";
import {MarketOperationsFacet} from "src/facets/market/MarketOperationsFacet.sol";

// Market facet interfaces
import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {IMarketViewFacet} from "src/interfaces/IMarketViewFacet.sol";
import {IMarketOperationsFacet} from "src/interfaces/IMarketOperationsFacet.sol";

abstract contract DiamondMarketTestBase is Test {
    address internal diamond;

    // Core facets
    DiamondCutFacet internal diamondCutFacet;
    DiamondLoupeFacet internal diamondLoupeFacet;
    OwnershipFacet internal ownershipFacet;

    // Market facets
    MarketConfigFacet internal marketConfigFacet;
    MarketViewFacet internal marketViewFacet;
    MarketOperationsFacet internal marketOpsFacet;

    // Helper to assemble facet cut entry
    function _cutAdd(address facet, bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors});
    }

    function _deployDiamondAndFacets() internal {
        // Deploy core facets
        diamondCutFacet = new DiamondCutFacet();
        diamondLoupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();

        // Deploy market facets
        marketConfigFacet = new MarketConfigFacet();
        marketViewFacet = new MarketViewFacet();
        marketOpsFacet = new MarketOperationsFacet();

        // Deploy diamond root with this test contract as initial owner
        diamond = address(new DiamondHitch(address(this), address(diamondCutFacet)));

        // Build selectors per facet
        bytes4[] memory cutSelectors = new bytes4[](4);
        cutSelectors[0] = IDiamondCut.diamondCut.selector;
        cutSelectors[1] = IDiamondLoupe.facets.selector; // allow minimal loupe during setup (optional)
        cutSelectors[2] = IDiamondLoupe.facetAddresses.selector;
        cutSelectors[3] = IDiamondLoupe.facetFunctionSelectors.selector;

        bytes4[] memory loupeSelectors = new bytes4[](4);
        loupeSelectors[0] = IDiamondLoupe.facets.selector;
        loupeSelectors[1] = IDiamondLoupe.facetAddresses.selector;
        loupeSelectors[2] = IDiamondLoupe.facetFunctionSelectors.selector;
        loupeSelectors[3] = IDiamondLoupe.facetAddress.selector;

        bytes4[] memory ownSelectors = new bytes4[](4);
        ownSelectors[0] = OwnershipFacet.owner.selector;
        ownSelectors[1] = OwnershipFacet.transferOwnership.selector;
        ownSelectors[2] = OwnershipFacet.acceptOwnership.selector;
        ownSelectors[3] = OwnershipFacet.renounceOwnership.selector;

        // Market Config selectors
        bytes4[] memory cfgSelectors = new bytes4[](8);
        cfgSelectors[0] = IMarketConfigFacet.initMarket.selector;
        cfgSelectors[1] = IMarketConfigFacet.setMarketFee.selector;
        cfgSelectors[2] = IMarketConfigFacet.setFeeRecipient.selector;
        cfgSelectors[3] = IMarketConfigFacet.setAllowedPaymentToken.selector;
        cfgSelectors[4] = IMarketConfigFacet.pause.selector;
        cfgSelectors[5] = IMarketConfigFacet.unpause.selector;
        cfgSelectors[6] = IMarketConfigFacet.initAccessManager.selector;
        cfgSelectors[7] = IMarketConfigFacet.setAccessManager.selector;

        // Market View selectors
        bytes4[] memory viewSelectors = new bytes4[](11);
        viewSelectors[0] = IMarketViewFacet.loan.selector;
        viewSelectors[1] = IMarketViewFacet.marketFeeBps.selector;
        viewSelectors[2] = IMarketViewFacet.feeRecipient.selector;
        viewSelectors[3] = IMarketViewFacet.isOperatorFor.selector;
        viewSelectors[4] = IMarketViewFacet.allowedPaymentToken.selector;
        viewSelectors[5] = IMarketViewFacet.getListing.selector;
        viewSelectors[6] = IMarketViewFacet.getTotalCost.selector;
        viewSelectors[7] = IMarketViewFacet.getOffer.selector;
        viewSelectors[8] = IMarketViewFacet.isListingActive.selector;
        viewSelectors[9] = IMarketViewFacet.isOfferActive.selector;
        viewSelectors[10] = IMarketViewFacet.canOperate.selector;

        // Market Ops selectors
        bytes4[] memory opsSelectors = new bytes4[](10);
        opsSelectors[0] = IMarketOperationsFacet.makeListing.selector;
        opsSelectors[1] = IMarketOperationsFacet.updateListing.selector;
        opsSelectors[2] = IMarketOperationsFacet.cancelListing.selector;
        opsSelectors[3] = IMarketOperationsFacet.takeListing.selector;
        opsSelectors[4] = IMarketOperationsFacet.createOffer.selector;
        opsSelectors[5] = IMarketOperationsFacet.updateOffer.selector;
        opsSelectors[6] = IMarketOperationsFacet.cancelOffer.selector;
        opsSelectors[7] = IMarketOperationsFacet.acceptOffer.selector;
        opsSelectors[8] = IMarketOperationsFacet.matchOfferWithListing.selector;
        opsSelectors[9] = IMarketOperationsFacet.setOperatorApproval.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](5);
        cut[0] = _cutAdd(address(diamondLoupeFacet), loupeSelectors);
        cut[1] = _cutAdd(address(ownershipFacet), ownSelectors);
        cut[2] = _cutAdd(address(marketConfigFacet), cfgSelectors);
        cut[3] = _cutAdd(address(marketViewFacet), viewSelectors);
        cut[4] = _cutAdd(address(marketOpsFacet), opsSelectors);

        // Perform cut
        IDiamondCut(diamond).diamondCut(cut, address(0), "");
    }

    function _initMarket(address loan, address votingEscrow, uint16 feeBps, address feeRecipient, address defaultToken) internal {
        IMarketConfigFacet(diamond).initMarket(loan, votingEscrow, feeBps, feeRecipient, defaultToken);
    }
}


