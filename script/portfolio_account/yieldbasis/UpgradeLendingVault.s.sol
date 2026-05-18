// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {LendingVault} from "../../../src/facets/account/vault/LendingVault.sol";

/**
 * Deploys a fresh LendingVault implementation and prints the multisig calldata
 * for upgrading the live UUPS proxy. Does NOT broadcast the upgrade itself --
 * the proxy owner (multisig) submits that tx separately.
 *
 * This upgrade fixes a JIT sandwich vector on mid-epoch depositRewards() by
 * grossing up the incoming amount by WEEK/remaining inside _accumulateEpochReward.
 * It also appends a new storage slot `currentEpochActualRewards` that holds
 * the truthful sum of rewards deposited this epoch; lastEpochReward() now
 * reads from that slot. The new slot zero-initializes on the upgraded impl
 * and self-heals on the next depositRewards() call in a fresh epoch.
 *
 * Env:
 *   VAULT_PROXY  -- UUPS proxy to upgrade (defaults to ETH mainnet yb-WETH supplyVault).
 *
 * Run (deploy + verify, broadcasts only the impl deploy):
 *   forge script script/portfolio_account/yieldbasis/UpgradeLendingVault.s.sol:UpgradeLendingVault \
 *     --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
 */
contract UpgradeLendingVault is Script {
    address public constant DEFAULT_VAULT_PROXY = 0x204bEE4cFDAa7b318333bCA8f5612c8164F74Ba3;

    function run() external {
        address proxy = vm.envOr("VAULT_PROXY", DEFAULT_VAULT_PROXY);
        require(proxy.code.length > 0, "VAULT_PROXY has no code");

        // Read pre-upgrade owner for the calldata banner. Owner is the only
        // address authorized to call upgradeToAndCall on the proxy.
        address ownerAddr;
        try LendingVault(proxy).owner() returns (address o) {
            ownerAddr = o;
        } catch {
            ownerAddr = address(0);
        }

        vm.startBroadcast();
        LendingVault newImpl = new LendingVault();
        vm.stopBroadcast();

        console.log("New impl deployed:", address(newImpl));
        console.log("Proxy to upgrade :", proxy);
        console.log("Proxy owner      :", ownerAddr);
        console.log("");

        // Plain upgrade. currentEpochActualRewards zero-initializes; lastEpochReward()
        // returns 0 until the next depositRewards() lands in a fresh epoch (self-healing).
        bytes memory plain = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)", address(newImpl), bytes("")
        );
        console.log("--- upgradeToAndCall(newImpl, \"\") ---");
        console.log("to   :", proxy);
        console.log("data :");
        console.logBytes(plain);
    }
}
