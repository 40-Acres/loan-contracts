// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title MarketDeployInitVELO
 * @notice Deploys VELO Market Diamond on Optimism (wallet + external adapters only)
 * @dev Script 1: Deploy wallet-only marketplace. Run MarketDeployLoanListingsVELO.s.sol for loan features.
 * 
 * Usage:
 *   PRIVATE_KEY=0x... forge script script/MarketDeployInitVELO.s.sol:MarketDeployInitVELO \
 *     --rpc-url $BASE_RPC_URL --broadcast --verify
 * 
 * Save the output addresses and update MarketDeployLoanListingsVELO.s.sol before running Script 2.
 */

import {Script, console} from "forge-std/Script.sol";

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

// External adapter facets
import {VexyAdapterFacet} from "src/facets/market/VexyAdapterFacet.sol";
import {OpenXAdapterFacet} from "src/facets/market/OpenXAdapterFacet.sol";

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

contract MarketDeployInitVELO is Script {
    
    // @dev configure deployment
    // ============================================================================
    // CONFIGURATION - Update these for different chains/markets
    // ============================================================================
    
    // Chain: OP Mainnet
    uint256 constant CHAIN_ID = 10;
    
    // Core token addresses
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant VELO = 0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db;
    address constant VOTING_ESCROW = 0xFAf8FD17D9840595845582fCB047DF13f006787d; // veVELO
    
    // Market fees (in basis points, 100 = 1%)
    uint16 constant BASE_MARKET_FEE_BPS = 100;      // 1% for wallet/loan listings
    uint16 constant EXTERNAL_MARKET_FEE_BPS = 200;  // 2% for external adapters
    uint16 constant LBO_LENDER_FEE_BPS = 100;       // 1% LBO lender fee
    uint16 constant LBO_PROTOCOL_FEE_BPS = 100;     // 1% LBO protocol fee
    
    // Fee recipient (set to address(0) to use deployer)
    address constant FEE_RECIPIENT = address(0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23);

    // ============================================================================
    // State
    // ============================================================================
    
    // Payment tokens to enable
    address[] paymentTokens;

    // struct for external adapters
    struct ExternalAdapter {
        string key;
        address adapterFacet;
    }
    
    // External adapters
    ExternalAdapter[] externalAdapters;
    
    address internal diamond;
    
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
    
    // External adapter facets
    VexyAdapterFacet internal vexyAdapterFacet;
    OpenXAdapterFacet internal openXAdapterFacet;

    function run() external {
        // @dev Configure payment tokens
        paymentTokens.push(USDC);
        paymentTokens.push(VELO);
        //
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("");
        console.log("=== VELO Market Diamond Deployment (OP Mainnet) ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", CHAIN_ID);
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy diamond and facets
        address diamondAddress = deployMarketDiamond(deployer);
        
        // Determine fee recipient
        address feeRecipient = FEE_RECIPIENT == address(0) ? deployer : FEE_RECIPIENT;
        
        // Initialize market
        console.log("Initializing market...");
        IMarketConfigFacet(diamondAddress).initMarket(
            address(0), // No loan contract initially
            VOTING_ESCROW,
            BASE_MARKET_FEE_BPS,
            EXTERNAL_MARKET_FEE_BPS,
            LBO_LENDER_FEE_BPS,
            LBO_PROTOCOL_FEE_BPS,
            feeRecipient,
            USDC // Default payment token
        );
        
        // Set payment tokens config
        console.log("");
        console.log("Configuring payment tokens...");
        for (uint i = 0; i < paymentTokens.length; i++) {
            IMarketConfigFacet(diamondAddress).setAllowedPaymentToken(paymentTokens[i], true);
            console.log("- Enabled:", paymentTokens[i]);
        }

        // @dev Configure external adapters
        externalAdapters.push(ExternalAdapter({key: "VEXY", adapterFacet: address(vexyAdapterFacet)}));
        externalAdapters.push(ExternalAdapter({key: "OPENX", adapterFacet: address(openXAdapterFacet)}));
        //
        
        // Register external adapters
        console.log("");
        console.log("Registering external adapters...");
        for (uint i = 0; i < externalAdapters.length; i++) {
            bytes32 key = keccak256(abi.encodePacked(externalAdapters[i].key));
            IMarketConfigFacet(diamondAddress).setExternalAdapter(key, address(externalAdapters[i].adapterFacet));
            console.log("-", externalAdapters[i].key, "adapter enabled");
        }
        
        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Diamond:", diamondAddress);
        console.log("");
        console.log("=== SAVE THESE FOR SCRIPT 2 ===");
        console.log("DIAMOND_ADDRESS=", diamondAddress);
        console.log("LOAN_LISTINGS_FACET_ADDRESS=", address(loanListingsFacet));
        console.log("");
        console.log("Update MarketDeployLoanListingsVELO.s.sol with these addresses to enable loan features.");
        
        vm.stopBroadcast();
    }

    function _cutAdd(address facet, bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });
    }

    function deployMarketDiamond(address owner) internal returns (address) {
        // Deploy core facets
        console.log("Deploying core facets...");
        diamondCutFacet = new DiamondCutFacet();
        diamondLoupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();

        // Deploy market facets
        console.log("Deploying market facets...");
        marketConfigFacet = new MarketConfigFacet();
        marketViewFacet = new MarketViewFacet();
        loanListingsFacet = new MarketListingsLoanFacet();
        walletListingsFacet = new MarketListingsWalletFacet();
        offerFacet = new MarketOfferFacet();
        matchingFacet = new MarketMatchingFacet();
        operatorFacet = new MarketOperatorFacet();
        routerFacet = new MarketRouterFacet();
        
        // Deploy external adapter facets
        console.log("Deploying external adapter facets...");
        vexyAdapterFacet = new VexyAdapterFacet();
        openXAdapterFacet = new OpenXAdapterFacet();

        // Deploy diamond root
        console.log("Deploying diamond root...");
        diamond = address(new DiamondHitch(owner, address(diamondCutFacet)));

        // Build selectors per facet
        console.log("Building function selectors...");
        
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

        bytes4[] memory cfgSelectors = new bytes4[](14);
        cfgSelectors[0] = IMarketConfigFacet.initMarket.selector;
        cfgSelectors[1] = IMarketConfigFacet.setMarketFee.selector;
        cfgSelectors[2] = IMarketConfigFacet.setFeeRecipient.selector;
        cfgSelectors[3] = IMarketConfigFacet.setAllowedPaymentToken.selector;
        cfgSelectors[4] = IMarketConfigFacet.pause.selector;
        cfgSelectors[5] = IMarketConfigFacet.unpause.selector;
        cfgSelectors[6] = IMarketConfigFacet.initAccessManager.selector;
        cfgSelectors[7] = IMarketConfigFacet.setAccessManager.selector;
        cfgSelectors[8] = IMarketConfigFacet.setPermit2.selector;
        cfgSelectors[9] = IMarketConfigFacet.setExternalAdapter.selector;
        cfgSelectors[10] = IMarketConfigFacet.setLBOLenderFeeBps.selector;
        cfgSelectors[11] = IMarketConfigFacet.setLBOProtocolFeeBps.selector;
        cfgSelectors[12] = IMarketConfigFacet.setLoan.selector;
        cfgSelectors[13] = IMarketConfigFacet.setLoanAsset.selector;

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

        bytes4[] memory walletSelectors = new bytes4[](5);
        walletSelectors[0] = IMarketListingsWalletFacet.makeWalletListing.selector;
        walletSelectors[1] = IMarketListingsWalletFacet.updateWalletListing.selector;
        walletSelectors[2] = IMarketListingsWalletFacet.cancelWalletListing.selector;
        walletSelectors[3] = IMarketListingsWalletFacet.takeWalletListing.selector;
        walletSelectors[4] = IMarketListingsWalletFacet.takeWalletListingFor.selector;
        
        bytes4[] memory walletSelectors2 = new bytes4[](1);
        walletSelectors2[0] = IMarketListingsWalletFacet.quoteWalletListing.selector;

        bytes4[] memory offerSelectors = new bytes4[](4);
        offerSelectors[0] = IMarketOfferFacet.createOffer.selector;
        offerSelectors[1] = IMarketOfferFacet.updateOffer.selector;
        offerSelectors[2] = IMarketOfferFacet.cancelOffer.selector;
        offerSelectors[3] = IMarketOfferFacet.acceptOffer.selector;

        bytes4[] memory matchingSelectors = new bytes4[](2);
        matchingSelectors[0] = IMarketMatchingFacet.matchOfferWithLoanListing.selector;
        matchingSelectors[1] = IMarketMatchingFacet.matchOfferWithWalletListing.selector;

        bytes4[] memory operatorSelectors = new bytes4[](1);
        operatorSelectors[0] = IMarketOperatorFacet.setOperatorApproval.selector;

        bytes4[] memory routerSelectors = new bytes4[](4);
        routerSelectors[0] = IMarketRouterFacet.quoteToken.selector;
        routerSelectors[1] = IMarketRouterFacet.buyToken.selector;
        routerSelectors[2] = IMarketRouterFacet.buyTokenWithLBO.selector;
        routerSelectors[3] = IFlashLoanReceiver.onFlashLoan.selector;
        
        bytes4[] memory adapterSelectors = new bytes4[](2);
        adapterSelectors[0] = bytes4(keccak256("quoteToken(uint256,bytes)"));
        adapterSelectors[1] = bytes4(keccak256("buyToken(uint256,uint256,address,uint256,bytes,bytes,bytes)"));

        // Perform diamond cuts (skip LoanListingsFacet - added in Script 2)
        console.log("Performing diamond cuts...");
        
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](10);
        cut[0] = _cutAdd(address(diamondLoupeFacet), loupeSelectors);
        cut[1] = _cutAdd(address(ownershipFacet), ownSelectors);
        cut[2] = _cutAdd(address(marketConfigFacet), cfgSelectors);
        cut[3] = _cutAdd(address(marketViewFacet), viewSelectors);
        cut[4] = _cutAdd(address(walletListingsFacet), walletSelectors);
        cut[5] = _cutAdd(address(offerFacet), offerSelectors);
        cut[6] = _cutAdd(address(matchingFacet), matchingSelectors);
        cut[7] = _cutAdd(address(routerFacet), routerSelectors);
        cut[8] = _cutAdd(address(vexyAdapterFacet), adapterSelectors);
        cut[9] = _cutAdd(address(openXAdapterFacet), adapterSelectors);

        IDiamondCut(diamond).diamondCut(cut, address(0), "");
        
        // Add wallet listing quote selector separately (function overload)
        IDiamondCut.FacetCut[] memory cutWallet = new IDiamondCut.FacetCut[](1);
        cutWallet[0] = _cutAdd(address(walletListingsFacet), walletSelectors2);
        IDiamondCut(diamond).diamondCut(cutWallet, address(0), "");

        // Add operator selectors
        IDiamondCut.FacetCut[] memory cut2 = new IDiamondCut.FacetCut[](1);
        cut2[0] = _cutAdd(address(operatorFacet), operatorSelectors);
        IDiamondCut(diamond).diamondCut(cut2, address(0), "");

        console.log("Diamond deployment complete!");
        
        return diamond;
    }
}

