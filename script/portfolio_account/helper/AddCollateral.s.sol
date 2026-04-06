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
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
/**
 * @title AddCollateral
 * @dev Helper script to add collateral via PortfolioManager multicall
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 *
 * Usage:
 * 1. Single token: TOKEN_ID=1 forge script script/portfolio_account/helper/AddCollateral.s.sol:AddCollateral --sig "run()" --rpc-url $RPC_URL --broadcast
 * 2. Multiple tokens: TOKEN_IDS="1,2,3" forge script script/portfolio_account/helper/AddCollateral.s.sol:AddCollateral --sig "runBatch()" --rpc-url $RPC_URL --broadcast
 */
contract AddCollateral is Script {
    using stdJson for string;

    /**
     * @dev Add multiple tokens as collateral via PortfolioManager multicall
     * @param tokenIds Array of token IDs to add as collateral
     * @param owner The owner address (for getting portfolio from factory)
     */
    function addCollateral(
        uint256[] memory tokenIds,
        address owner
    ) internal {
        require(tokenIds.length > 0, "No token IDs provided");

        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(vm, portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = BaseCollateralFacet.addCollateral.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "CollateralFacet.addCollateral not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory for token approval
        address portfolioAddress = factory.portfolioOf(owner);
        if (portfolioAddress == address(0)) {
            portfolioAddress = factory.createAccount(owner);
        }

        // Get VE address from the registered collateral facet
        address ve = BaseCollateralFacet(facet).getCollateralToken();

        // Approve and build multicall for all tokens
        address[] memory factories = new address[](tokenIds.length);
        bytes[] memory calldatas = new bytes[](tokenIds.length);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            IVotingEscrow(ve).approve(portfolioAddress, tokenIds[i]);
            factories[i] = address(factory);
            calldatas[i] = abi.encodeWithSelector(selector, tokenIds[i]);
        }

        portfolioManager.multicall(calldatas, factories);

        console.log("Collateral added successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Tokens added:", tokenIds.length);

        uint256 totalCollateral = CollateralFacet(portfolioAddress).getTotalLockedCollateral();
        console.log("Total Locked Collateral:", totalCollateral);
    }

    /**
     * @dev Run with a single token ID from env
     * Usage: TOKEN_ID=1 PRIVATE_KEY=0x... forge script ... --sig "run()"
     */
    function run() external {
        uint256 tokenId = vm.envUint("TOKEN_ID");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        vm.startBroadcast(privateKey);
        addCollateral(tokenIds, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Run with multiple token IDs from env (comma-separated)
     * Usage: TOKEN_IDS="1,2,3" PRIVATE_KEY=0x... forge script ... --sig "runBatch()"
     */
    function runBatch() external {
        uint256[] memory tokenIds = vm.envUint("TOKEN_IDS", ",");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        addCollateral(tokenIds, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// TOKEN_ID=64196 forge script script/portfolio_account/helper/AddCollateral.s.sol:AddCollateral --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
// TOKEN_IDS="109382,64196,12345" forge script script/portfolio_account/helper/AddCollateral.s.sol:AddCollateral --sig "runBatch()" --rpc-url $BASE_RPC_URL --broadcast
