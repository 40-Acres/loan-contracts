// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {VotingEscrowFacet} from "../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title CreateLock
 * @dev Helper script to create a voting escrow lock via PortfolioManager multicall
 * 
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 * 
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/CreateLock.s.sol:CreateLock --sig "run(uint256,uint256)" <AMOUNT> <LOCK_DURATION> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: AMOUNT=1000000000000000000 LOCK_DURATION=31536000 forge script script/portfolio_account/helper/CreateLock.s.sol:CreateLock --sig "run()" --rpc-url $RPC_URL --broadcast
 * 
 * Example:
 * forge script script/portfolio_account/helper/CreateLock.s.sol:CreateLock --sig "run(uint256,uint256)" 1000000000000000000 31536000 --rpc-url $BASE_RPC_URL --broadcast
 */
contract CreateLock is Script {
    using stdJson for string;

    /**
     * @dev Get voting escrow address - hardcoded for Aerodrome on Base
     */
    function getVotingEscrow() internal pure returns (address) {
        return 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4; // Aerodrome veAERO on Base
    }

    /**
     * @dev Create a lock via PortfolioManager multicall
     * @param amount The amount of tokens to lock (in wei)
     * @param lockDuration The lock duration in seconds
     * @param owner The owner address (for token approval)
     * @return tokenId The token ID of the created lock
     */
    function createLock(
        uint256 amount,
        uint256 lockDuration,
        address owner
    ) internal returns (uint256 tokenId) {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);
        
        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = VotingEscrowFacet.createLock.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "VotingEscrowFacet.createLock not registered in FacetRegistry. Please deploy facets first.");
        
        // Get portfolio address from factory for token approval
        address portfolioAddress = factory.portfolioOf(owner);
        if (portfolioAddress == address(0)) {
            // Portfolio will be created by multicall, but we need it for approval
            // We'll create it here to get the address
            portfolioAddress = factory.createAccount(owner);
        }
        
        // Get voting escrow and underlying token
        address votingEscrowAddr = getVotingEscrow();
        IVotingEscrow votingEscrow = IVotingEscrow(votingEscrowAddr);
        address tokenAddress = votingEscrow.token();
        IERC20 token = IERC20(tokenAddress);
        
        // Approve portfolio account to spend tokens from owner
        uint256 currentAllowance = token.allowance(owner, portfolioAddress);
        if (currentAllowance < amount) {
            // Use vm.broadcast to sign as the owner (we're already in broadcast mode)
            token.approve(portfolioAddress, type(uint256).max);
            console.log("Approved portfolio to spend tokens");
        }
        
        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);
        
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            amount
        );
        
        bytes[] memory results = portfolioManager.multicall(calldatas, factories);
        require(results.length > 0, "Multicall failed - no results");
        
        tokenId = abi.decode(results[0], (uint256));
        
        console.log("Lock created successfully!");
        console.log("Token ID:", tokenId);
        console.log("Amount:", amount);
        console.log("Lock Duration:", lockDuration);
        
        return tokenId;
    }

    /**
     * @dev Main run function for forge script execution
     * @param amount The amount of tokens to lock (in wei)
     * @param lockDuration The lock duration in seconds
     */
    function run(
        uint256 amount,
        uint256 lockDuration
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        createLock(amount, lockDuration, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... AMOUNT=1000000000000000000 LOCK_DURATION=31536000 forge script script/portfolio_account/helper/CreateLock.s.sol:CreateLock --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        uint256 amount = vm.envUint("AMOUNT");
        uint256 lockDuration = 125193600;
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        
        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        
        vm.startBroadcast(privateKey);
        createLock(amount, lockDuration, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// AMOUNT=1000000000000000000 forge script script/portfolio_account/helper/CreateLock.s.sol:CreateLock --sig "run()" --rpc-url $BASE_RPC_URL --broadcast

