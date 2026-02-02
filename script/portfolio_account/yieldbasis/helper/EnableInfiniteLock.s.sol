// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {YieldBasisFacet} from "../../../../src/facets/account/yieldbasis/YieldBasisFacet.sol";
import {IYieldBasisVotingEscrow} from "../../../../src/interfaces/IYieldBasisVotingEscrow.sol";
import {PortfolioHelperUtils} from "../../../utils/PortfolioHelperUtils.sol";

/**
 * @title EnableInfiniteLock
 * @dev Helper script to enable infinite lock on an existing portfolio's veYB position
 *
 * This is needed for portfolios created before infinite lock was the default.
 * Infinite lock is required for veYB transfers (including removeCollateral).
 *
 * Usage:
 * forge script script/portfolio_account/yieldbasis/helper/EnableInfiniteLock.s.sol:EnableInfiniteLock --rpc-url $ETH_RPC_URL --broadcast
 */
contract EnableInfiniteLock is Script {
    // YieldBasis Contract Addresses (Ethereum Mainnet)
    address public constant VE_YB = 0x8235c179E9e84688FBd8B12295EfC26834dAC211;

    function enableInfiniteLock(address owner) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Get YieldBasis factory
        PortfolioFactory factory = PortfolioHelperUtils.getYieldBasisFactory(vm, portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();

        // Check if enableInfiniteLock is registered
        bytes4 selector = YieldBasisFacet.enableInfiniteLock.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "YieldBasisFacet.enableInfiniteLock not registered. Please upgrade facets first.");

        // Get portfolio address
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "No portfolio found for owner");

        // Check current lock status
        IYieldBasisVotingEscrow veYB = IYieldBasisVotingEscrow(VE_YB);
        IYieldBasisVotingEscrow.LockedBalance memory lock = veYB.locked(portfolioAddress);

        console.log("Portfolio:", portfolioAddress);
        console.log("Lock amount:", uint256(uint128(lock.amount)));
        console.log("Lock end:", lock.end);

        if (lock.amount == 0) {
            console.log("ERROR: No existing lock found");
            revert("No existing lock to enable infinite lock on");
        }

        if (lock.end == type(uint256).max) {
            console.log("Infinite lock is already enabled!");
            return;
        }

        console.log("Enabling infinite lock...");

        // Call enableInfiniteLock via multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(selector);

        portfolioManager.multicall(calldatas, factories);

        // Verify
        lock = veYB.locked(portfolioAddress);
        console.log("New lock end:", lock.end);
        require(lock.end == type(uint256).max, "Failed to enable infinite lock");
        console.log("Infinite lock enabled successfully!");
    }

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        enableInfiniteLock(owner);
        vm.stopBroadcast();
    }
}

// Usage:
// forge script script/portfolio_account/yieldbasis/helper/EnableInfiniteLock.s.sol:EnableInfiniteLock --rpc-url $ETH_RPC_URL --broadcast
