// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {YieldBasisVotingFacet} from "../../../../src/facets/account/yieldbasis/YieldBasisVotingFacet.sol";
import {YieldBasisFacet} from "../../../../src/facets/account/yieldbasis/YieldBasisFacet.sol";
import {IYieldBasisVotingEscrow} from "../../../../src/interfaces/IYieldBasisVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../../utils/PortfolioHelperUtils.sol";

/**
 * @title CreateLock (YieldBasis)
 * @dev Helper script to create a veYB lock via PortfolioManager multicall
 *
 * veYB locks are always MAX LOCKED (4 years). The lock duration is automatically
 * set to the maximum.
 *
 * Portfolio is automatically determined from the factory using the owner address (from PRIVATE_KEY).
 *
 * Usage:
 * 1. With parameters: forge script script/portfolio_account/yieldbasis/helper/CreateLock.s.sol:CreateLock --sig "run(uint256)" <AMOUNT> --rpc-url $ETH_RPC_URL --broadcast
 * 2. From env vars: AMOUNT=1000000000000000000 forge script script/portfolio_account/yieldbasis/helper/CreateLock.s.sol:CreateLock --sig "run()" --rpc-url $ETH_RPC_URL --broadcast
 *
 * Example:
 * forge script script/portfolio_account/yieldbasis/helper/CreateLock.s.sol:CreateLock --sig "run(uint256)" 1000000000000000000 --rpc-url $ETH_RPC_URL --broadcast
 */
contract CreateLock is Script {
    using stdJson for string;

    // YieldBasis Contract Addresses (Ethereum Mainnet)
    address public constant VE_YB = 0x8235c179E9e84688FBd8B12295EfC26834dAC211;

    /**
     * @dev Get YB token address from veYB contract
     */
    function getYBToken() internal view returns (address) {
        return 0x01791F726B4103694969820be083196cC7c045fF;
    }

    /**
     * @dev Create a max-locked veYB position via PortfolioManager multicall
     * @param amount The amount of YB tokens to lock (in wei)
     * @param owner The owner address (for token approval)
     */
    function createLock(
        uint256 amount,
        address owner
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Get YieldBasis factory
        PortfolioFactory factory = PortfolioHelperUtils.getYieldBasisFactory(vm, portfolioManager);
        FacetRegistry facetRegistry = factory.facetRegistry();
        bytes4 selector = YieldBasisFacet.createLock.selector;
        address facet = facetRegistry.getFacetForSelector(selector);
        require(facet != address(0), "YieldBasisFacet.createLock not registered in FacetRegistry. Please deploy facets first.");

        // Get portfolio address from factory for token approval
        address portfolioAddress = factory.portfolioOf(owner);
        if (portfolioAddress == address(0)) {
            // Portfolio will be created by multicall, but we need it for approval
            portfolioAddress = factory.createAccount(owner);
            console.log("Created new portfolio:", portfolioAddress);
        }

        // Get YB token and approve portfolio to spend tokens
        address ybToken = getYBToken();
        IERC20 token = IERC20(ybToken);

        uint256 currentAllowance = token.allowance(owner, portfolioAddress);
        if (currentAllowance < amount) {
            token.approve(portfolioAddress, type(uint256).max);
            console.log("Approved portfolio to spend YB tokens");
        }

        // Use factory address for multicall
        address[] memory factories = new address[](1);
        factories[0] = address(factory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(selector, amount);

        portfolioManager.multicall(calldatas, factories);

        console.log("veYB lock created successfully!");
        console.log("Portfolio Address:", portfolioAddress);
        console.log("Amount Locked:", amount);
        console.log("Lock Duration: 4 years (max lock)");
    }

    /**
     * @dev Main run function for forge script execution
     * @param amount The amount of YB tokens to lock (in wei)
     */
    function run(uint256 amount) external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);
        vm.startBroadcast(privateKey);
        createLock(amount, owner);
        vm.stopBroadcast();
    }

    /**
     * @dev Alternative run function that reads parameters from environment variables
     * Usage: PRIVATE_KEY=0x... AMOUNT=1000000000000000000 forge script script/portfolio_account/yieldbasis/helper/CreateLock.s.sol:CreateLock --sig "run()" --rpc-url $ETH_RPC_URL --broadcast
     */
    function run() external {
        uint256 amount = vm.envUint("AMOUNT");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = PortfolioHelperUtils.getAddressFromPrivateKey(vm, privateKey);

        vm.startBroadcast(privateKey);
        createLock(amount, owner);
        vm.stopBroadcast();
    }
}

// Example usage:
// AMOUNT=1000000000000000000 forge script script/portfolio_account/yieldbasis/helper/CreateLock.s.sol:CreateLock --sig "run()" --rpc-url $ETH_RPC_URL --broadcast
