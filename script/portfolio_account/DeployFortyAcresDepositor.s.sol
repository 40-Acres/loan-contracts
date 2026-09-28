// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {FortyAcresDepositor} from "../../src/accounts/FortyAcresDepositor.sol";

/**
 * @title DeployFortyAcresDepositor
 * @dev Deploys the per-chain FortyAcresDepositor with CREATE2. The contract has
 *      no owner and its manager set is fixed at construction, so there is
 *      nothing to configure afterwards: deploy, verify, add the address to
 *      `addresses/<network>/<platform>.json` under `depositor`.
 *
 *      The address depends on the salt and the constructor args (the manager
 *      list), so it is identical across chains only where the managers are.
 *
 * Environment:
 *   FORTY_ACRES_DEPLOYER  - deployer private key
 *   PORTFOLIO_MANAGERS    - comma-separated PortfolioManager addresses
 *                           (one per protocol on this chain, e.g. aerodrome,hydrex on Base)
 *   DEPOSITOR_SALT        - (optional) bytes32 CREATE2 salt
 *
 * Usage:
 *   PORTFOLIO_MANAGERS=0xAero...,0xHydrex... \
 *   forge script script/portfolio_account/DeployFortyAcresDepositor.s.sol:DeployFortyAcresDepositor \
 *     --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
 */
contract DeployFortyAcresDepositor is Script {
    bytes32 public constant DEFAULT_SALT = keccak256("FortyAcresDepositor.v1");

    function run() external {
        address[] memory managers = vm.envAddress("PORTFOLIO_MANAGERS", ",");
        bytes32 salt = vm.envOr("DEPOSITOR_SALT", DEFAULT_SALT);
        require(managers.length > 0, "PORTFOLIO_MANAGERS is empty");
        for (uint256 i = 0; i < managers.length; i++) {
            require(managers[i].code.length > 0, "manager has no code");
        }

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        FortyAcresDepositor depositor = new FortyAcresDepositor{salt: salt}(managers);
        vm.stopBroadcast();

        console.log("=== FortyAcresDepositor Deployed ===");
        console.log("Address :", address(depositor));
        console.log("Chain ID:", block.chainid);
        for (uint256 i = 0; i < managers.length; i++) {
            console.log("Manager :", managers[i]);
        }
        console.log("");
        console.log("Next: add `depositor` to addresses/<network>/<platform>.json, changeset, publish.");
    }
}
