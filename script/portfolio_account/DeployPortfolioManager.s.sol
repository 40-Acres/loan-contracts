// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PortfolioManager} from "../../src/accounts/PortfolioManager.sol";

/**
 * @title DeployPortfolioManager
 * @dev Deploys PortfolioManager with CREATE2 for deterministic addresses across chains.
 *
 * The same deployer + salt produces the same address on every EVM chain,
 * enabling cross-chain consistency for the PortfolioManager hub.
 *
 * Usage:
 *   forge script script/portfolio_account/DeployPortfolioManager.s.sol:DeployPortfolioManager \
 *     --chain-id <id> --rpc-url <url> --broadcast --verify --via-ir
 *
 * Environment:
 *   FORTY_ACRES_DEPLOYER - deployer private key
 *   PM_OWNER             - (optional) owner address, defaults to multisig
 */
contract DeployPortfolioManager is Script {
    address public constant MULTISIG_ADDRESS = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;

    // CREATE2 salt — DO NOT CHANGE.
    bytes32 public constant PM_SALT = bytes32(uint256(0x0000000000000000000000000000000000000000000000000e000005c6c57005));

    function run() external {
        uint256 deployerKey = vm.envUint("FORTY_ACRES_DEPLOYER");
        address owner = vm.envOr("PM_OWNER", MULTISIG_ADDRESS);

        vm.startBroadcast(deployerKey);

        PortfolioManager pm = new PortfolioManager{salt: PM_SALT}(owner);
        require(address(pm) == 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec, "Unexpected PM address");

        vm.stopBroadcast();

        console.log("=== PortfolioManager Deployed ===");
        console.log("Address:", address(pm));
        console.log("Owner:", owner);
        console.log("Chain ID:", block.chainid);
    }
}

// Ethereum Mainnet (chain-id 1):
// forge script script/portfolio_account/DeployPortfolioManager.s.sol:DeployPortfolioManager --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
//
// Base (chain-id 8453):
// forge script script/portfolio_account/DeployPortfolioManager.s.sol:DeployPortfolioManager --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
//
// Optimism (chain-id 10):
// forge script script/portfolio_account/DeployPortfolioManager.s.sol:DeployPortfolioManager --chain-id 10 --rpc-url $OP_RPC_URL --broadcast --verify --via-ir
//
// Avalanche (chain-id 43114):
// forge script script/portfolio_account/DeployPortfolioManager.s.sol:DeployPortfolioManager --chain-id 43114 --rpc-url $AVAX_RPC_URL --broadcast --verify --via-ir
//
// Linea (chain-id 59144):
// forge script script/portfolio_account/DeployPortfolioManager.s.sol:DeployPortfolioManager --chain-id 59144 --rpc-url $LINEA_RPC_URL --broadcast --verify --via-ir
//
// Ink (chain-id 57073):
// forge script script/portfolio_account/DeployPortfolioManager.s.sol:DeployPortfolioManager --chain-id 57073 --rpc-url $INK_RPC_URL --broadcast --verify --via-ir
