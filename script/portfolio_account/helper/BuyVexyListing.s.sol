// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {VexyFacet} from "../../../src/facets/account/marketplace/VexyFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {IVexyMarketplace} from "../../../src/interfaces/external/IVexyMarketplace.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title BuyVexyListing
 * @dev Helper script to buy a veNFT from the Vexy marketplace via PortfolioManager multicall
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 * The buyer must approve the portfolio account to spend the payment token before calling.
 * The purchased veNFT is automatically added as collateral in the portfolio.
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/BuyVexyListing.s.sol:BuyVexyListing --sig "run(uint256)" <LISTING_ID> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: LISTING_ID=1 forge script script/portfolio_account/helper/BuyVexyListing.s.sol:BuyVexyListing --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/BuyVexyListing.s.sol:BuyVexyListing --sig "run(uint256)" 123 --rpc-url $BASE_RPC_URL --broadcast
 */
contract BuyVexyListing is Script {
    using stdJson for string;

    IVexyMarketplace constant VEXY = IVexyMarketplace(0x6b478209974BD27e6cf661FEf86C68072b0d6738);

    /**
     * @dev Buy a Vexy listing via PortfolioManager multicall
     * @param listingId The Vexy marketplace listing ID
     * @param buyer The buyer's address (portfolio owner)
     */
    function buyVexyListing(
        uint256 listingId,
        address buyer
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = VexyFacet.buyVexyListing.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "VexyFacet.buyVexyListing not registered in FacetRegistry. Please deploy facets first.");

        // Get or create portfolio address from factory
        address portfolioAddress = factory.portfolioOf(buyer);
        if (portfolioAddress == address(0)) {
            console.log("Creating new portfolio for buyer:", buyer);
            portfolioAddress = factory.createAccount(buyer);
            console.log("Portfolio created at:", portfolioAddress);
        }

        // Get listing details from Vexy
        (
            ,
            ,
            ,
            uint256 nftId,
            address currency,
            ,
            ,
            ,
            ,
            ,
            uint64 soldTime
        ) = VEXY.listings(listingId);
        require(soldTime == 0, "Listing already sold");

        uint256 price = VEXY.listingPrice(listingId);
        require(price > 0, "Invalid listing price");

        console.log("Vexy Listing Details:");
        console.log("  Listing ID:", listingId);
        console.log("  NFT ID:", nftId);
        console.log("  Currency:", currency);
        console.log("  Price:", price);

        // Check buyer has approved the portfolio
        IERC20 paymentToken = IERC20(currency);
        uint256 allowance = paymentToken.allowance(buyer, portfolioAddress);
        if(allowance < price) {
            paymentToken.approve(portfolioAddress, price);
        }

        // Check buyer has sufficient balance
        uint256 balance = paymentToken.balanceOf(buyer);
        require(balance >= price, "Insufficient balance");

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            listingId,
            buyer
        );

        portfolioManager.multicall(calldatas, factories);

        console.log("Purchase successful!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("NFT ID added as collateral:", nftId);

        // Check updated collateral
        uint256 totalCollateral = CollateralFacet(portfolioAddress).getTotalLockedCollateral();
        console.log("Total locked collateral:", totalCollateral);
    }

    /**
     * @dev Main run function for forge script execution
     * @param listingId The Vexy marketplace listing ID
     */
    function run(
        uint256 listingId
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address buyer = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        buyVexyListing(listingId, buyer);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... LISTING_ID=1 forge script script/portfolio_account/helper/BuyVexyListing.s.sol:BuyVexyListing --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        uint256 listingId = vm.envUint("LISTING_ID");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Get buyer address from private key
        address buyer = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        buyVexyListing(listingId, buyer);
        vm.stopBroadcast();
    }
}

// Example usage:
// LISTING_ID=123 forge script script/portfolio_account/helper/BuyVexyListing.s.sol:BuyVexyListing --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
