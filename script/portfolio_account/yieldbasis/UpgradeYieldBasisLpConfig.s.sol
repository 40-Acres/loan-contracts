// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {YieldBasisPortfolioFactoryConfig} from "../../../src/facets/account/config/YieldBasisPortfolioFactoryConfig.sol";

/**
 * Deploys a fresh YieldBasisPortfolioFactoryConfig implementation and prints
 * the multisig calldata for upgrading the live UUPS proxy. Does NOT broadcast
 * the upgrade itself — the proxy owner (multisig) submits that tx separately.
 *
 * Env:
 *   PFC_PROXY     — UUPS proxy to upgrade (defaults to ETH mainnet yb-WETH PFC).
 *   STAKED_MODE   — optional "true"/"false". When set, the printed calldata
 *                   bundles setStakedGaugeMode(<value>) into upgradeToAndCall.
 *                   When unset, prints upgradeToAndCall(impl, "") (no init call).
 *
 * Run (deploy + verify, broadcasts only the impl deploy):
 *   forge script script/portfolio_account/yieldbasis/UpgradeYieldBasisLpConfig.s.sol:UpgradeYieldBasisLpConfig \
 *     --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
 */
contract UpgradeYieldBasisLpConfig is Script {
    address public constant DEFAULT_PFC_PROXY = 0x8706FD061241266959e6A6E9e084f34935087012;

    function run() external {
        address proxy = vm.envOr("PFC_PROXY", DEFAULT_PFC_PROXY);
        require(proxy.code.length > 0, "PFC_PROXY has no code");

        // Read pre-upgrade state for the calldata banner. Owner is the only
        // address authorized to call upgradeToAndCall on the proxy.
        address ownerAddr;
        try YieldBasisPortfolioFactoryConfig(proxy).owner() returns (address o) {
            ownerAddr = o;
        } catch {
            ownerAddr = address(0);
        }

        vm.startBroadcast();
        YieldBasisPortfolioFactoryConfig newImpl = new YieldBasisPortfolioFactoryConfig();
        vm.stopBroadcast();

        console.log("New impl deployed:", address(newImpl));
        console.log("Proxy to upgrade :", proxy);
        console.log("Proxy owner      :", ownerAddr);
        console.log("");

        // Variant A: plain upgrade. stakedGaugeMode stays at zero-init (false).
        bytes memory plain = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)", address(newImpl), bytes("")
        );
        console.log("--- Variant A: upgradeToAndCall(newImpl, \"\")  [stakedGaugeMode = false] ---");
        console.log("to   :", proxy);
        console.log("data :");
        console.logBytes(plain);
        console.log("");

        // Variant B: bundle setStakedGaugeMode into the upgrade. Use only when
        // the post-upgrade default must be deliberate (e.g. enabling auto-stake
        // on day one for the live yb-WETH gauge).
        string memory stakedModeStr = vm.envOr("STAKED_MODE", string(""));
        if (bytes(stakedModeStr).length > 0) {
            bool desired = vm.envBool("STAKED_MODE");
            bytes memory initData = abi.encodeCall(
                YieldBasisPortfolioFactoryConfig.setStakedGaugeMode, (desired)
            );
            bytes memory bundled = abi.encodeWithSignature(
                "upgradeToAndCall(address,bytes)", address(newImpl), initData
            );
            console.log("--- Variant B: upgradeToAndCall(newImpl, setStakedGaugeMode(<bool>)) ---");
            console.log("stakedGaugeMode :", desired);
            console.log("to   :", proxy);
            console.log("data :");
            console.logBytes(bundled);
        } else {
            console.log("--- Variant B: skipped (set STAKED_MODE=true|false to render) ---");
        }
    }
}
