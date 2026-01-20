// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {UserMarketplaceModule} from "../../../src/facets/account/marketplace/UserMarketplaceModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";

/**
 * @title BuyMarketplaceListing
 * @dev Helper script to buy a veNFT from the 40 Acres marketplace as an external buyer (not a portfolio account)
 *
 * This is for external buyers who want to purchase a veNFT directly without having a portfolio account.
 * The buyer must approve the seller's portfolio account to spend the payment token before calling.
 * NOTE: This is NOT via multicall - it's a direct call to the seller's portfolio account.
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/BuyMarketplaceListing.s.sol:BuyMarketplaceListing --sig "run(address,uint256)" <SELLER_PORTFOLIO> <TOKEN_ID> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: SELLER_PORTFOLIO=0x... TOKEN_ID=1 forge script script/portfolio_account/helper/BuyMarketplaceListing.s.sol:BuyMarketplaceListing --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/BuyMarketplaceListing.s.sol:BuyMarketplaceListing --sig "run(address,uint256)" 0x1234... 109384 --rpc-url $BASE_RPC_URL --broadcast
 */
contract BuyMarketplaceListing is Script {
    using stdJson for string;

    /**
     * @dev Buy a marketplace listing from external buyer
     * @param sellerPortfolio The seller's portfolio account address
     * @param tokenId The veNFT token ID to buy
     * @param buyer The buyer's address
     */
    function buyMarketplaceListing(
        address sellerPortfolio,
        uint256 tokenId,
        address buyer
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(portfolioManager);

        // Verify seller portfolio exists
        require(factory.isPortfolio(sellerPortfolio), "Seller portfolio does not exist");

        // Get listing details
        MarketplaceFacet marketplaceFacet = MarketplaceFacet(sellerPortfolio);
        UserMarketplaceModule.Listing memory listing = marketplaceFacet.getListing(tokenId);
        require(listing.owner != address(0), "Listing does not exist");

        console.log("Listing Details:");
        console.log("  Token ID:", tokenId);
        console.log("  Price:", listing.price);
        console.log("  Payment Token:", listing.paymentToken);
        console.log("  Debt Attached:", listing.debtAttached);
        console.log("  Expires At:", listing.expiresAt);
        console.log("  Allowed Buyer:", listing.allowedBuyer);

        // Check buyer has approved the seller portfolio
        IERC20 paymentToken = IERC20(listing.paymentToken);
        uint256 allowance = paymentToken.allowance(buyer, sellerPortfolio);
        uint256 totalRequired = listing.price + listing.debtAttached;
        require(allowance >= totalRequired, "Insufficient allowance. Please approve the seller portfolio first.");

        // Check buyer has sufficient balance
        uint256 balance = paymentToken.balanceOf(buyer);
        require(balance >= totalRequired, "Insufficient balance");

        // Buy the listing
        marketplaceFacet.buyMarketplaceListing(tokenId, buyer);

        console.log("Purchase successful!");
        console.log("Buyer:", buyer);
        console.log("Amount paid:", totalRequired);
    }

    /**
     * @dev Main run function for forge script execution
     * @param sellerPortfolio The seller's portfolio account address
     * @param tokenId The veNFT token ID to buy
     */
    function run(
        address sellerPortfolio,
        uint256 tokenId
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address buyer = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        buyMarketplaceListing(sellerPortfolio, tokenId, buyer);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... SELLER_PORTFOLIO=0x... TOKEN_ID=1 forge script script/portfolio_account/helper/BuyMarketplaceListing.s.sol:BuyMarketplaceListing --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        address sellerPortfolio = vm.envAddress("SELLER_PORTFOLIO");
        uint256 tokenId = vm.envUint("TOKEN_ID");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Get buyer address from private key
        address buyer = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        buyMarketplaceListing(sellerPortfolio, tokenId, buyer);
        vm.stopBroadcast();
    }
}

// Example usage:
// SELLER_PORTFOLIO=0x1234... TOKEN_ID=109384 forge script script/portfolio_account/helper/BuyMarketplaceListing.s.sol:BuyMarketplaceListing --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
