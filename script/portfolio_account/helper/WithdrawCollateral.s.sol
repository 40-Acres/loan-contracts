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
 * @title WithdrawCollateral
 * @dev Helper script to withdraw collateral via PortfolioManager multicall
 * 
 * Portfolio address can be loaded from addresses.json (field: "portfolioaddress" or "portfolioAddress")
 * or passed as a parameter/environment variable.
 * 
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/WithdrawCollateral.s.sol:WithdrawCollateral --sig "run(address,uint256)" <PORTFOLIO_ADDRESS> <TOKEN_ID> --rpc-url $RPC_URL --broadcast
 * 2. From addresses.json + env vars: TOKEN_ID=1 forge script script/portfolio_account/helper/WithdrawCollateral.s.sol:WithdrawCollateral --sig "run()" --rpc-url $RPC_URL --broadcast
 * 
 * Example:
 * forge script script/portfolio_account/helper/WithdrawCollateral.s.sol:WithdrawCollateral --sig "run(address,uint256)" 0x123... 1 --rpc-url $BASE_RPC_URL --broadcast
 */
contract WithdrawCollateral is Script {
    using stdJson for string;

    /**
     * @dev Withdraw collateral via PortfolioManager multicall
     * @param portfolioAddress The portfolio account address
     * @param tokenId The token ID of the voting escrow NFT to withdraw from collateral
     */
    function withdrawCollateral(
        address portfolioAddress,
        uint256 tokenId
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);
        
        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = CollateralFacet.removeCollateral.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "CollateralFacet.removeCollateral not registered in FacetRegistry. Please deploy facets first.");
        
        // Use factory address instead of portfolio address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);
        
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            tokenId
        );
        
        portfolioManager.multicall(calldatas, factories);
        
        console.log("Collateral withdrawn successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Token ID:", tokenId);
        
        // Optionally check the total locked collateral after withdrawal
        uint256 totalCollateral = CollateralFacet(portfolioAddress).getTotalLockedCollateral();
        console.log("Total Locked Collateral (after withdrawal):", totalCollateral);
    }

    /**
     * @dev Main run function for forge script execution
     * @param portfolioAddress The portfolio account address
     * @param tokenId The token ID of the voting escrow NFT to withdraw from collateral
     */
    function run(
        address portfolioAddress,
        uint256 tokenId
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);
        withdrawCollateral(portfolioAddress, tokenId);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from addresses.json and environment variables
     * Portfolio address is loaded from addresses.json if available, otherwise from PORTFOLIO_ADDRESS env var,
     * or from PRIVATE_KEY/OWNER env var using the aerodrome-usdc factory
     * Usage: PRIVATE_KEY=0x... TOKEN_ID=1 forge script script/portfolio_account/helper/WithdrawCollateral.s.sol:WithdrawCollateral --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        uint256 tokenId = vm.envUint("TOKEN_ID");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        
        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        
        vm.startBroadcast(privateKey);
        
        // Get or create portfolio (must happen during broadcast)
        // Always use owner-based lookup when PRIVATE_KEY is available to ensure portfolio exists
        address portfolioAddress = PortfolioHelperUtils.getPortfolioForOwner(vm, owner);

        
        withdrawCollateral(portfolioAddress, tokenId);
        vm.stopBroadcast();
    }
}

// Example usage:
// TOKEN_ID=109382 forge script script/portfolio_account/helper/WithdrawCollateral.s.sol:WithdrawCollateral --sig "run()" --rpc-url $BASE_RPC_URL --broadcast

