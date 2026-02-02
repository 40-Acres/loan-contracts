// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {CollateralFacet} from "../../../../src/facets/account/collateral/CollateralFacet.sol";
import {IYieldBasisVotingEscrow} from "../../../../src/interfaces/IYieldBasisVotingEscrow.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../../utils/PortfolioHelperUtils.sol";

/**
 * @title RemoveCollateral (YieldBasis)
 * @dev Helper script to remove veYB collateral via PortfolioManager multicall
 *
 * This transfers a veYB NFT from the portfolio account back to the owner's wallet
 * and unregisters it as collateral.
 *
 * IMPORTANT: For veYB, the receiver (owner) must have an existing max-locked position.
 * When the veYB is transferred, it will merge with the owner's existing lock.
 * If the owner doesn't have a lock, the transfer will fail.
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 * Token ID is automatically retrieved from the portfolio's veYB position.
 *
 * Usage:
 * forge script script/portfolio_account/yieldbasis/helper/RemoveCollateral.s.sol:RemoveCollateral --rpc-url $ETH_RPC_URL --broadcast
 */
contract RemoveCollateral is Script {
    using stdJson for string;

    // YieldBasis Contract Addresses (Ethereum Mainnet)
    address public constant VE_YB = 0x8235c179E9e84688FBd8B12295EfC26834dAC211;

    /**
     * @dev Remove veYB collateral via PortfolioManager multicall
     * @param owner The owner address (for getting portfolio from factory)
     */
    function removeCollateral(
        address owner
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Get YieldBasis factory
        PortfolioFactory factory = PortfolioHelperUtils.getYieldBasisFactory(vm, portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = CollateralFacet.removeCollateral.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "CollateralFacet.removeCollateral not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "No portfolio found for owner");

        // Get veYB contract and retrieve token ID from portfolio
        IYieldBasisVotingEscrow veYB = IYieldBasisVotingEscrow(VE_YB);

        // Get the token ID owned by the portfolio (index 0)
        uint256 tokenId = veYB.tokenOfOwnerByIndex(portfolioAddress, 0);
        console.log("Found veYB token ID:", tokenId);

        // Check if owner has a lock with infinite lock enabled (required for veYB transfer)
        IYieldBasisVotingEscrow.LockedBalance memory ownerLock = veYB.locked(owner);
        if (ownerLock.amount == 0) {
            console.log("WARNING: Owner does not have an existing veYB lock.");
            console.log("The transfer will fail. Please create a lock first.");
            revert("Owner must have an existing veYB lock to receive collateral");
        }
        // Infinite lock is indicated by lock.end == type(uint256).max
        if (ownerLock.end != type(uint256).max) {
            console.log("WARNING: Owner's veYB lock does not have infinite lock enabled.");
            console.log("Owner lock end:", ownerLock.end);
            console.log("Required (max uint256):", type(uint256).max);
            console.log("Please call infinite_lock_toggle() on your veYB position first.");
            revert("Owner must have infinite lock enabled to receive collateral");
        }

        // Get lock info before removing
        IYieldBasisVotingEscrow.LockedBalance memory portfolioLock = veYB.locked(portfolioAddress);
        console.log("Portfolio locked amount:", uint256(uint128(portfolioLock.amount)));
        console.log("Portfolio unlock time:", portfolioLock.end);
        console.log("Owner locked amount:", uint256(uint128(ownerLock.amount)));
        console.log("Owner unlock time:", ownerLock.end);

        // Get current debt to ensure we can remove
        uint256 currentDebt = CollateralFacet(portfolioAddress).getTotalDebt();
        if (currentDebt > 0) {
            console.log("WARNING: Portfolio has outstanding debt:", currentDebt);
            console.log("Removing collateral may fail if it would undercollateralize the loan.");
        }

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(selector, tokenId);

        portfolioManager.multicall(calldatas, factories);

        console.log("Collateral removed successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Token ID:", tokenId);
        console.log("Transferred to:", owner);

        // Note: The veYB has merged with owner's existing lock
        IYieldBasisVotingEscrow.LockedBalance memory newOwnerLock = veYB.locked(owner);
        console.log("Owner new locked amount:", uint256(uint128(newOwnerLock.amount)));

        // Get remaining collateral
        uint256 totalCollateral = CollateralFacet(portfolioAddress).getTotalLockedCollateral();
        console.log("Remaining Locked Collateral:", totalCollateral);
    }

    /**
     * @dev Main run function for forge script execution
     */
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        removeCollateral(owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// forge script script/portfolio_account/yieldbasis/helper/RemoveCollateral.s.sol:RemoveCollateral --rpc-url $ETH_RPC_URL --broadcast
