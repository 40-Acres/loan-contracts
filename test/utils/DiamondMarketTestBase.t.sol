// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "lib/forge-std/src/Test.sol";
import {Loan} from "src/LoanV2.sol";

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

import {MarketListingsLoanFacet} from "src/facets/market/MarketListingsLoanFacet.sol";
import {MarketListingsWalletFacet} from "src/facets/market/MarketListingsWalletFacet.sol";
import {MarketOfferFacet} from "src/facets/market/MarketOfferFacet.sol";
import {MarketMatchingFacet} from "src/facets/market/MarketMatchingFacet.sol";
import {MarketOperatorFacet} from "src/facets/market/MarketOperatorFacet.sol";
import {MarketRouterFacet} from "src/facets/market/MarketRouterFacet.sol";

// Market facet interfaces
import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {IMarketViewFacet} from "src/interfaces/IMarketViewFacet.sol";

import {IMarketListingsLoanFacet} from "src/interfaces/IMarketListingsLoanFacet.sol";
import {IMarketListingsWalletFacet} from "src/interfaces/IMarketListingsWalletFacet.sol";
import {IMarketOfferFacet} from "src/interfaces/IMarketOfferFacet.sol";
import {IMarketMatchingFacet} from "src/interfaces/IMarketMatchingFacet.sol";
import {IMarketOperatorFacet} from "src/interfaces/IMarketOperatorFacet.sol";
import {IMarketRouterFacet} from "src/interfaces/IMarketRouterFacet.sol";
import {IFlashLoanReceiver} from "src/interfaces/IFlashLoanReceiver.sol";

// Minimal Ownable view for on-chain proxy via implementation ABI
interface IOwnableLike { function owner() external view returns (address); }

abstract contract DiamondMarketTestBase is Test {
    address internal diamond;
    address internal constant BASE_LOAN_CANONICAL = 0x87f18b377e625b62c708D5f6EA96EC193558EFD0;

    // Core facets
    DiamondCutFacet internal diamondCutFacet;
    DiamondLoupeFacet internal diamondLoupeFacet;
    OwnershipFacet internal ownershipFacet;

    // Market facets
    MarketConfigFacet internal marketConfigFacet;
    MarketViewFacet internal marketViewFacet;

    MarketListingsLoanFacet internal loanListingsFacet;
    MarketListingsWalletFacet internal walletListingsFacet;
    MarketOfferFacet internal offerFacet;
    MarketMatchingFacet internal matchingFacet;
    MarketOperatorFacet internal operatorFacet;
    MarketRouterFacet internal routerFacet;
    IMarketRouterFacet internal router;

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

        loanListingsFacet = new MarketListingsLoanFacet();
        walletListingsFacet = new MarketListingsWalletFacet();
        offerFacet = new MarketOfferFacet();
        matchingFacet = new MarketMatchingFacet();
        operatorFacet = new MarketOperatorFacet();
        routerFacet = new MarketRouterFacet();

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
        bytes4[] memory cfgSelectors = new bytes4[](12);
        cfgSelectors[0] = IMarketConfigFacet.initMarket.selector;
        cfgSelectors[1] = IMarketConfigFacet.setMarketFee.selector;
        cfgSelectors[2] = IMarketConfigFacet.setFeeRecipient.selector;
        cfgSelectors[3] = IMarketConfigFacet.setAllowedPaymentToken.selector;
        cfgSelectors[4] = IMarketConfigFacet.pause.selector;
        cfgSelectors[5] = IMarketConfigFacet.unpause.selector;
        cfgSelectors[6] = IMarketConfigFacet.initAccessManager.selector;
        cfgSelectors[7] = IMarketConfigFacet.setAccessManager.selector;
        // Permit2 config
        cfgSelectors[8] = IMarketConfigFacet.setPermit2.selector;
        // External adapter registry
        cfgSelectors[9] = IMarketConfigFacet.setExternalAdapter.selector;
        // LBO fee config
        cfgSelectors[10] = IMarketConfigFacet.setLBOLenderFeeBps.selector;
        cfgSelectors[11] = IMarketConfigFacet.setLBOProtocolFeeBps.selector;

        // Market View selectors
        bytes4[] memory viewSelectors = new bytes4[](13);
        viewSelectors[0] = IMarketViewFacet.loan.selector;
        viewSelectors[1] = IMarketViewFacet.marketFeeBps.selector;
        viewSelectors[2] = IMarketViewFacet.feeRecipient.selector;
        viewSelectors[3] = IMarketViewFacet.isOperatorFor.selector;
        viewSelectors[4] = IMarketViewFacet.allowedPaymentToken.selector;
        viewSelectors[5] = IMarketViewFacet.getListing.selector;
        viewSelectors[6] = IMarketViewFacet.getOffer.selector;
        viewSelectors[7] = IMarketViewFacet.isListingActive.selector;
        viewSelectors[8] = IMarketViewFacet.isOfferActive.selector;
        viewSelectors[9] = IMarketViewFacet.canOperate.selector;
        viewSelectors[10] = IMarketViewFacet.loanAsset.selector;
        viewSelectors[11] = IMarketViewFacet.getLBOLenderFeeBps.selector;
        viewSelectors[12] = IMarketViewFacet.getLBOProtocolFeeBps.selector;

        // Loan listings selectors
        bytes4[] memory loanSelectors = new bytes4[](8);
        loanSelectors[0] = IMarketListingsLoanFacet.makeLoanListing.selector;
        loanSelectors[1] = IMarketListingsLoanFacet.updateLoanListing.selector;
        loanSelectors[2] = IMarketListingsLoanFacet.cancelLoanListing.selector;
        loanSelectors[3] = bytes4(keccak256("takeLoanListing(uint256,address)"));           // (uint256,address)
        loanSelectors[4] = IMarketListingsLoanFacet.takeLoanListingWithPermit.selector; // (uint256,address,PermitSingle,bytes)
        loanSelectors[5] = IMarketListingsLoanFacet.quoteLoanListing.selector;          // (uint256,address)
        loanSelectors[6] = bytes4(keccak256("takeLoanListing(uint256,address,uint256,bytes,bytes)"));
        loanSelectors[7] = IMarketListingsLoanFacet.takeLoanListingFor.selector;

        // Wallet listings selectors
        bytes4[] memory walletSelectors = new bytes4[](5);
        walletSelectors[0] = IMarketListingsWalletFacet.makeWalletListing.selector;
        walletSelectors[1] = IMarketListingsWalletFacet.updateWalletListing.selector;
        walletSelectors[2] = IMarketListingsWalletFacet.cancelWalletListing.selector;
        walletSelectors[3] = IMarketListingsWalletFacet.takeWalletListing.selector;           // unified entry
        walletSelectors[4] = IMarketListingsWalletFacet.takeWalletListingFor.selector;        // router-only entry
        // quote
        bytes4[] memory walletSelectors2 = new bytes4[](1);
        walletSelectors2[0] = IMarketListingsWalletFacet.quoteWalletListing.selector;          // simplified

        // Offers selectors
        bytes4[] memory offerSelectors = new bytes4[](4);
        offerSelectors[0] = IMarketOfferFacet.createOffer.selector;
        offerSelectors[1] = IMarketOfferFacet.updateOffer.selector;
        offerSelectors[2] = IMarketOfferFacet.cancelOffer.selector;
        offerSelectors[3] = IMarketOfferFacet.acceptOffer.selector;

        // Matching selectors
        bytes4[] memory matchingSelectors = new bytes4[](2);
        matchingSelectors[0] = IMarketMatchingFacet.matchOfferWithLoanListing.selector;
        matchingSelectors[1] = IMarketMatchingFacet.matchOfferWithWalletListing.selector;

        // Operator selectors
        bytes4[] memory operatorSelectors = new bytes4[](1);
        operatorSelectors[0] = IMarketOperatorFacet.setOperatorApproval.selector;

        // Router selectors
        bytes4[] memory routerSelectors = new bytes4[](4);
        routerSelectors[0] = IMarketRouterFacet.quoteToken.selector;
        routerSelectors[1] = IMarketRouterFacet.buyToken.selector;
        routerSelectors[2] = IMarketRouterFacet.buyTokenWithLBO.selector;
        routerSelectors[3] = IFlashLoanReceiver.onFlashLoan.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](9);
        cut[0] = _cutAdd(address(diamondLoupeFacet), loupeSelectors);
        cut[1] = _cutAdd(address(ownershipFacet), ownSelectors);
        cut[2] = _cutAdd(address(marketConfigFacet), cfgSelectors);
        cut[3] = _cutAdd(address(marketViewFacet), viewSelectors);
        cut[4] = _cutAdd(address(loanListingsFacet), loanSelectors);
        cut[5] = _cutAdd(address(walletListingsFacet), walletSelectors);
        cut[6] = _cutAdd(address(offerFacet), offerSelectors);
        cut[7] = _cutAdd(address(matchingFacet), matchingSelectors);
        cut[8] = _cutAdd(address(routerFacet), routerSelectors);

        // Perform cut
        IDiamondCut(diamond).diamondCut(cut, address(0), "");
        IDiamondCut.FacetCut[] memory cutWallet = new IDiamondCut.FacetCut[](1);
        cutWallet[0] = _cutAdd(address(walletListingsFacet), walletSelectors2);
        IDiamondCut(diamond).diamondCut(cutWallet, address(0), "");

        // Add operator selectors
        IDiamondCut.FacetCut[] memory cut2 = new IDiamondCut.FacetCut[](1);
        cut2[0] = _cutAdd(address(operatorFacet), operatorSelectors);
        IDiamondCut(diamond).diamondCut(cut2, address(0), "");

        // Cache router interface for child tests
        router = IMarketRouterFacet(diamond);
    }

    function upgradeCanonicalLoan() internal {
        address proxy = BASE_LOAN_CANONICAL;
        // Deploy current implementation
        Loan impl = new Loan();
        address loanOwner = Loan(proxy).owner();
        // Impersonate owner and attempt upgrade; ignore failures to keep tests resilient
        vm.startPrank(loanOwner);
        try Loan(proxy).upgradeToAndCall(address(impl), new bytes(0)) {
        } catch { }
        vm.stopPrank();
    }

    function _initMarket(address loan, address votingEscrow, uint16 baseMarketFeeBps, uint16 externalMarketFeeBps, uint16 lboLenderFeeBps, uint16 lboProtocolFeeBps, address feeRecipient, address defaultToken) internal {
        IMarketConfigFacet(diamond).initMarket(loan, votingEscrow, baseMarketFeeBps, externalMarketFeeBps, lboLenderFeeBps, lboProtocolFeeBps, feeRecipient, defaultToken);
        // prank as loan owner set our new diamond as approved contract inside loanv2
        vm.prank(Loan(loan).owner());
        Loan(loan).setMarketDiamond(diamond);
    }
}


