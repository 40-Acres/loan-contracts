// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title RemoveCollateralTo
 * @dev Helper script to move veNFT collateral from one factory's portfolio to another and lock it as collateral there.
 *
 * Performs two operations in a single multicall:
 * 1. removeCollateralTo - removes from source factory and transfers veNFT to target portfolio
 * 2. addCollateral - locks the veNFT as collateral in the target portfolio
 *
 * Both factories must be registered in the same PortfolioManager.
 * The target portfolio is auto-created if it doesn't exist.
 *
 * Environment variables:
 * - PRIVATE_KEY: Signer private key (portfolio owner)
 * - FACTORY_SALT: Source factory salt (default: "aerodrome-usdc")
 * - TARGET_FACTORY_SALT: Target factory salt (e.g., "aerodrome-usdc-dynamic-fees", "yieldbasis-usdc-v2")
 * - TOKEN_ID: (optional) veNFT token ID when using run()
 *
 * Usage:
 * 1. With parameters:
 *    TARGET_FACTORY_SALT=aerodrome-usdc-dynamic-fees forge script script/portfolio_account/helper/RemoveCollateralTo.s.sol:RemoveCollateralTo --sig "run(uint256)" <TOKEN_ID> --rpc-url $RPC_URL --broadcast
 *
 * 2. From env vars:
 *    TOKEN_ID=109384 TARGET_FACTORY_SALT=aerodrome-usdc-dynamic-fees forge script script/portfolio_account/helper/RemoveCollateralTo.s.sol:RemoveCollateralTo --sig "run()" --rpc-url $RPC_URL --broadcast
 */
contract RemoveCollateralTo is Script {
    using stdJson for string;

    /**
     * @dev Move collateral to a different factory's portfolio and lock it there via PortfolioManager multicall.
     *      Executes two operations in one multicall:
     *      1. removeCollateralTo(tokenId, targetFactory) on source factory
     *      2. addCollateral(tokenId) on target factory
     * @param tokenId The veNFT token ID to move
     * @param owner The owner address (for getting portfolio from factory)
     */
    function removeCollateralTo(
        uint256 tokenId,
        address owner
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Get source factory
        PortfolioFactory sourceFactory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);

        // Verify removeCollateralTo is registered on source
        FacetRegistry sourceFacetRegistry = sourceFactory.facetRegistry();
        bytes4 removeSelector = BaseCollateralFacet.removeCollateralTo.selector;
        address facet = sourceFacetRegistry.getFacetForSelector(removeSelector);
        require(facet != address(0), "CollateralFacet.removeCollateralTo not registered on source. Please deploy facets first.");

        // Get source portfolio
        address sourcePortfolio = sourceFactory.portfolioOf(owner);
        require(sourcePortfolio != address(0), "Source portfolio does not exist.");

        // Check collateral is locked
        uint256 lockedCollateral = CollateralFacet(sourcePortfolio).getLockedCollateral(tokenId);
        console.log("Locked collateral for token:", lockedCollateral);
        require(lockedCollateral > 0, "Token is not locked as collateral");

        // Get target factory from TARGET_FACTORY_SALT
        string memory targetSalt = vm.envString("TARGET_FACTORY_SALT");
        bytes32 salt = keccak256(abi.encodePacked(targetSalt));
        address targetFactoryAddr = portfolioManager.factoryBySalt(salt);
        require(targetFactoryAddr != address(0), string.concat("Target factory not found for salt: ", targetSalt));
        require(targetFactoryAddr != address(sourceFactory), "Target factory must be different from source factory. Use RemoveCollateral instead.");

        // Verify addCollateral is registered on target
        FacetRegistry targetFacetRegistry = PortfolioFactory(targetFactoryAddr).facetRegistry();
        bytes4 addSelector = BaseCollateralFacet.addCollateral.selector;
        address targetFacet = targetFacetRegistry.getFacetForSelector(addSelector);
        require(targetFacet != address(0), "CollateralFacet.addCollateral not registered on target. Please deploy facets first.");

        console.log("Source factory:", address(sourceFactory));
        console.log("Target factory:", targetFactoryAddr);

        // Build multicall with 2 operations:
        // 1. removeCollateralTo on source → transfers veNFT to target portfolio
        // 2. addCollateral on target → locks veNFT as collateral in target
        address[] memory factories = new address[](1);
        factories[0] = address(sourceFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            removeSelector,
            tokenId,
            targetFactoryAddr
        );

        portfolioManager.multicall(calldatas, factories);

        // Log results
        address targetPortfolio = PortfolioFactory(targetFactoryAddr).portfolioOf(owner);
        console.log("Collateral moved and locked successfully!");
        console.log("Source portfolio:", sourcePortfolio);
        console.log("Target portfolio:", targetPortfolio);
        console.log("Token ID:", tokenId);

        // Check updated collateral on both sides
        uint256 sourceCollateral = CollateralFacet(sourcePortfolio).getTotalLockedCollateral();
        uint256 targetCollateral = CollateralFacet(targetPortfolio).getTotalLockedCollateral();
        console.log("Source total locked collateral:", sourceCollateral);
        console.log("Target total locked collateral:", targetCollateral);
    }

    /**
     * @dev Main run function for forge script execution
     * @param tokenId The veNFT token ID to move
     */
    function run(
        uint256 tokenId
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        removeCollateralTo(tokenId, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     */
    function run() external {
        uint256 tokenId = vm.envUint("TOKEN_ID");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        removeCollateralTo(tokenId, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// FACTORY_SALT=aerodrome-usdc TOKEN_ID=109384 TARGET_FACTORY_SALT=aerodrome forge script script/portfolio_account/helper/RemoveCollateralTo.s.sol:RemoveCollateralTo --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
