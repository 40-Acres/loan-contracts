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
 * @title IncreaseLock
 * @dev Helper script to increase an existing voting escrow lock via PortfolioManager multicall
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/helper/IncreaseLock.s.sol:IncreaseLock --sig "run(uint256,uint256)" <TOKEN_ID> <AMOUNT> --rpc-url $RPC_URL --broadcast
 * 2. From env vars: TOKEN_ID=1 AMOUNT=1000000000000000000 forge script script/portfolio_account/helper/IncreaseLock.s.sol:IncreaseLock --sig "run()" --rpc-url $RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/helper/IncreaseLock.s.sol:IncreaseLock --sig "run(uint256,uint256)" 1 1000000000000000000 --rpc-url $BASE_RPC_URL --broadcast
 */
contract IncreaseLock is Script {
    using stdJson for string;

    /**
     * @dev Get voting escrow address - hardcoded for Aerodrome on Base
     */
    function getVotingEscrow() internal pure returns (address) {
        return 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4; // Aerodrome veAERO on Base
    }

    /**
     * @dev Increase a lock via PortfolioManager multicall
     * @param tokenId The token ID of the existing lock
     * @param amount The amount of tokens to add to the lock (in wei)
     * @param owner The owner address (for token approval)
     */
    function increaseLock(
        uint256 tokenId,
        uint256 amount,
        address owner
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Verify the facet is registered
        PortfolioFactory factory = PortfolioHelperUtils.getAerodromeFactory(portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = VotingEscrowFacet.increaseLock.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "VotingEscrowFacet.increaseLock not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory for token approval
        address portfolioAddress = factory.portfolioOf(owner);
        require(portfolioAddress != address(0), "Portfolio does not exist. Please add collateral first.");

        // Get voting escrow and underlying token
        address votingEscrowAddr = getVotingEscrow();
        IVotingEscrow votingEscrow = IVotingEscrow(votingEscrowAddr);
        address tokenAddress = votingEscrow.token();
        IERC20 token = IERC20(tokenAddress);

        // Approve portfolio account to spend tokens from owner
        uint256 currentAllowance = token.allowance(owner, portfolioAddress);
        if (currentAllowance < amount) {
            token.approve(portfolioAddress, type(uint256).max);
            console.log("Approved portfolio to spend tokens");
        }

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            selector,
            tokenId,
            amount
        );

        portfolioManager.multicall(calldatas, factories);

        console.log("Lock increased successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Token ID:", tokenId);
        console.log("Amount added:", amount);
    }

    /**
     * @dev Main run function for forge script execution
     * @param tokenId The token ID of the existing lock
     * @param amount The amount of tokens to add to the lock (in wei)
     */
    function run(
        uint256 tokenId,
        uint256 amount
    ) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        increaseLock(tokenId, amount, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... TOKEN_ID=1 AMOUNT=1000000000000000000 forge script script/portfolio_account/helper/IncreaseLock.s.sol:IncreaseLock --sig "run()" --rpc-url $RPC_URL --broadcast
     */
    function run() external {
        uint256 tokenId = vm.envUint("TOKEN_ID");
        uint256 amount = vm.envUint("AMOUNT");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        // Get owner address from private key
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        increaseLock(tokenId, amount, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// TOKEN_ID=109384 AMOUNT=1000000000000000000 forge script script/portfolio_account/helper/IncreaseLock.s.sol:IncreaseLock --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
