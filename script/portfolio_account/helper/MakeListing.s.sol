// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title MakeListing
 * @dev Helper script to create a marketplace listing for a veNFT via PortfolioManager multicall
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 * The veNFT must be locked as collateral in the portfolio.
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/MakeListing.s.sol:MakeListing --sig "run(uint256,uint256,address,uint256,uint256,address)" <TOKEN_ID> <PRICE> <PAYMENT_TOKEN> <DEBT_ATTACHED> <EXPIRES_AT> <ALLOWED_BUYER> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: TOKEN_ID=1 PRICE=1000000 PAYMENT_TOKEN=0x... DEBT_ATTACHED=0 EXPIRES_AT=0 ALLOWED_BUYER=0x0 forge script script/portfolio_account/helper/MakeListing.s.sol:MakeListing --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/MakeListing.s.sol:MakeListing --sig "run(uint256,uint256,address,uint256,uint256,address)" 109384 1000000000 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 0 0 0x0000000000000000000000000000000000000000 --rpc-url $BASE_RPC_URL --broadcast
 */
contract MakeListing is Script {
    using stdJson for string;

    /**
     * @dev Create a marketplace listing via PortfolioManager multicall
     * @param tokenId The veNFT token ID to list
     * @param price The listing price
     * @param paymentToken The token address for payment (e.g., USDC)
     * @param debtAttached Amount of debt to attach to the listing (0 = buyer pays off debt)
     * @param expiresAt Unix timestamp when listing expires (0 = never expires)
     * @param allowedBuyer Restrict to specific buyer (address(0) = anyone can buy)
     * @param owner The owner address (for getting portfolio from factory)
     */
    function makeListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 debtAttached,
        uint256 expiresAt,
        address allowedBuyer,
        address owner
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = MarketplaceFacet.makeListing.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "MarketplaceFacet.makeListing not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "Portfolio does not exist. Please add collateral first.");

        // Check token is locked as collateral
        uint256 lockedCollateral = CollateralFacet(portfolioAddress).getLockedCollateral(tokenId);
        require(lockedCollateral > 0, "Token is not locked as collateral");

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            tokenId,
            price,
            paymentToken,
            debtAttached,
            expiresAt,
            allowedBuyer
        );

        portfolioManager.multicall(calldatas, factories);

        console.log("Listing created successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Token ID:", tokenId);
        console.log("Price:", price);
        console.log("Payment Token:", paymentToken);
        console.log("Debt Attached:", debtAttached);
        console.log("Expires At:", expiresAt);
        console.log("Allowed Buyer:", allowedBuyer);
    }

    /**
     * @dev Main run function for forge script execution
     * @param tokenId The veNFT token ID to list
     * @param price The listing price
     * @param paymentToken The token address for payment
     * @param debtAttached Amount of debt to attach
     * @param expiresAt Unix timestamp when listing expires
     * @param allowedBuyer Restrict to specific buyer
     */
    function run(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 debtAttached,
        uint256 expiresAt,
        address allowedBuyer
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        makeListing(tokenId, price, paymentToken, debtAttached, expiresAt, allowedBuyer, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... TOKEN_ID=1 PRICE=1000000 PAYMENT_TOKEN=0x... DEBT_ATTACHED=0 EXPIRES_AT=0 ALLOWED_BUYER=0x0 forge script script/portfolio_account/helper/MakeListing.s.sol:MakeListing --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        uint256 tokenId = vm.envUint("TOKEN_ID");
        uint256 price = vm.envUint("PRICE");
        address paymentToken = vm.envAddress("PAYMENT_TOKEN");
        uint256 debtAttached = vm.envOr("DEBT_ATTACHED", uint256(0));
        uint256 expiresAt = vm.envOr("EXPIRES_AT", uint256(0));
        address allowedBuyer = vm.envOr("ALLOWED_BUYER", address(0));
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        makeListing(tokenId, price, paymentToken, debtAttached, expiresAt, allowedBuyer, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// TOKEN_ID=109384 PRICE=1000000000 PAYMENT_TOKEN=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 forge script script/portfolio_account/helper/MakeListing.s.sol:MakeListing --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
