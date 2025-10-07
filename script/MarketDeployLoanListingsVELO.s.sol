// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title MarketDeployLoanListingsVELO
 * @notice Enables loan listings and LBO for VELO Market Diamond on OP Mainnet
 * @dev Script 2: Run after MarketDeployInitVELO.s.sol to enable loan features
 * 
 * Prerequisites:
 * 1. Run MarketDeployInitVELO.s.sol first
 * 2. Update DIAMOND_ADDRESS and LOAN_LISTINGS_FACET_ADDRESS below
 * 3. Ensure LoanV2 is deployed with market functionality
 * 
 * Usage:
 *   PRIVATE_KEY=0x... forge script script/MarketDeployLoanListingsVELO.s.sol:MarketDeployLoanListingsVELO \
 *     --rpc-url $BASE_RPC_URL --broadcast
 */

import {Script, console} from "forge-std/Script.sol";
import {Loan} from "../src/LoanV2.sol";

// Diamond interfaces
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";

// Market facet interfaces
import {IMarketConfigFacet} from "src/interfaces/IMarketConfigFacet.sol";
import {IMarketListingsLoanFacet} from "src/interfaces/IMarketListingsLoanFacet.sol";

contract MarketDeployLoanListingsVELO is Script {
    
    // ============================================================================
    // CONFIGURATION - Update these from MarketDeployInitVELO.s.sol output
    // ============================================================================
    
    // @dev Configure Addresses from Script 1 output
    address constant DIAMOND_ADDRESS = 0x0000000000000000000000000000000000000000; // UPDATE THIS
    address constant LOAN_LISTINGS_FACET_ADDRESS = 0x0000000000000000000000000000000000000000; // UPDATE THIS
    
    // @dev Configure LoanV2 contract (must have market functionality)
    address constant LOAN_CONTRACT = 0xf132bD888897254521D13e2c401e109caABa06A7;
    
    // @dev Configure Loan asset (for LBO flash loans)
    address constant LOAN_ASSET = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // USDC on OP
    
    // @dev Configure LBO fees (in basis points, 100 = 1%)
    uint16 constant LBO_LENDER_FEE_BPS = 100;
    uint16 constant LBO_PROTOCOL_FEE_BPS = 100;
    
    // ============================================================================

    function run() external {
        require(DIAMOND_ADDRESS != address(0), "Update DIAMOND_ADDRESS from Script 1 output");
        require(LOAN_LISTINGS_FACET_ADDRESS != address(0), "Update LOAN_LISTINGS_FACET_ADDRESS from Script 1 output");
        require(LOAN_CONTRACT != address(0), "LOAN_CONTRACT not configured");
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("");
        console.log("=== Enable Loan Listings & LBO (VELO Market) ===");
        console.log("Deployer:", deployer);
        console.log("Diamond:", DIAMOND_ADDRESS);
        console.log("Loan Contract:", LOAN_CONTRACT);
        console.log("Loan Listings Facet:", LOAN_LISTINGS_FACET_ADDRESS);
        console.log("Loan Asset:", LOAN_ASSET);
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Step 1: Set the loan contract address
        console.log("Step 1: Setting loan contract...");
        IMarketConfigFacet(DIAMOND_ADDRESS).setLoan(LOAN_CONTRACT);
        console.log("Loan contract set");
        
        // Step 2: Set the loan asset (for LBO flash loans)
        console.log("");
        console.log("Step 2: Setting loan asset...");
        IMarketConfigFacet(DIAMOND_ADDRESS).setLoanAsset(LOAN_ASSET);
        console.log("Loan asset set");
        
        // Step 3: Build and perform diamond cut to add LoanListingsFacet
        console.log("");
        console.log("Step 3: Adding LoanListingsFacet...");
        
        bytes4[] memory loanSelectors = new bytes4[](8);
        loanSelectors[0] = IMarketListingsLoanFacet.makeLoanListing.selector;
        loanSelectors[1] = IMarketListingsLoanFacet.updateLoanListing.selector;
        loanSelectors[2] = IMarketListingsLoanFacet.cancelLoanListing.selector;
        loanSelectors[3] = bytes4(keccak256("cancelExpiredLoanListings(uint256[])"));
        loanSelectors[4] = IMarketListingsLoanFacet.quoteLoanListing.selector;
        loanSelectors[5] = bytes4(keccak256("takeLoanListing(uint256,address,uint256,bytes,bytes)"));
        loanSelectors[6] = IMarketListingsLoanFacet.takeLoanListingFor.selector;
        loanSelectors[7] = IMarketListingsLoanFacet.takeLoanListingWithPermit.selector;
        
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: LOAN_LISTINGS_FACET_ADDRESS,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: loanSelectors
        });
        
        IDiamondCut(DIAMOND_ADDRESS).diamondCut(cut, address(0), "");
        console.log("LoanListingsFacet added");
        
        // Step 4: Configure LBO fees (only if the current LBO fees in this script do not match the current LBO fees in the diamond)
        console.log("");
        console.log("Step 4: Configuring LBO fees...");
        IMarketConfigFacet(DIAMOND_ADDRESS).setLBOLenderFeeBps(LBO_LENDER_FEE_BPS);
        IMarketConfigFacet(DIAMOND_ADDRESS).setLBOProtocolFeeBps(LBO_PROTOCOL_FEE_BPS);
        console.log("LBO fees configured");
        
        // Step 5: Register diamond with loan contract
        console.log("");
        console.log("Step 5: Registering diamond with loan...");
        Loan(LOAN_CONTRACT).setMarketDiamond(DIAMOND_ADDRESS);
        console.log("Diamond registered");
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=== Loan Listings Enabled! ===");
        console.log("The VELO market now supports:");
        console.log("- Loan listings (NFTs in loan custody)");
        console.log("- LBO (Leveraged Buyout)");
        console.log("- Flash loans");
        console.log("");
    }
}

