// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title RemoveCollateral
 * @dev Helper script to remove veNFT collateral from a portfolio via PortfolioManager multicall
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 * The veNFT must not have an active listing. The token will be transferred back to the portfolio owner.
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/RemoveCollateral.s.sol:RemoveCollateral --sig "run(uint256)" <TOKEN_ID> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: TOKEN_ID=1 forge script script/portfolio_account/helper/RemoveCollateral.s.sol:RemoveCollateral --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/RemoveCollateral.s.sol:RemoveCollateral --sig "run(uint256)" 109384 --rpc-url $BASE_RPC_URL --broadcast
 */
contract RemoveCollateral is Script {
    using stdJson for string;

    /**
     * @dev Remove collateral via PortfolioManager multicall
     * @param tokenId The veNFT token ID to remove from collateral
     * @param owner The owner address (for getting portfolio from factory)
     */
    function removeCollateral(
        uint256 tokenId,
        address owner
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = CollateralFacet.removeCollateral.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "CollateralFacet.removeCollateral not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "Portfolio does not exist.");

        // Check current collateral value for this token
        uint256 lockedCollateral = CollateralFacet(portfolioAddress).getLockedCollateral(tokenId);
        console.log("Locked collateral for token:", lockedCollateral);
        require(lockedCollateral > 0, "Token is not locked as collateral");

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            tokenId
        );

        portfolioManager.multicall(calldatas, factories);

        console.log("Collateral removed successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Token ID:", tokenId);

        // Check updated collateral
        uint256 totalCollateral = CollateralFacet(portfolioAddress).getTotalLockedCollateral();
        console.log("Total locked collateral after removal:", totalCollateral);
    }

    /**
     * @dev Main run function for forge script execution
     * @param tokenId The veNFT token ID to remove from collateral
     */
    function run(
        uint256 tokenId
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        removeCollateral(tokenId, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... TOKEN_ID=1 forge script script/portfolio_account/helper/RemoveCollateral.s.sol:RemoveCollateral --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        uint256 tokenId = vm.envUint("TOKEN_ID");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        removeCollateral(tokenId, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// TOKEN_ID=109384 forge script script/portfolio_account/helper/RemoveCollateral.s.sol:RemoveCollateral --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
