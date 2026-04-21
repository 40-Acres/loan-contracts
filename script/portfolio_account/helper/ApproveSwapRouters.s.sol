// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";

/**
 * @title ApproveSwapRoutersEthereum
 * @dev Approves 0x and Odos swap routers on the Ethereum SwapConfig.
 *      Must be called by the SwapConfig owner (deployer).
 *
 * Usage:
 *   forge script script/portfolio_account/helper/ApproveSwapRouters.s.sol:ApproveSwapRoutersEthereum \
 *     --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast
 */
contract ApproveSwapRoutersEthereum is Script {
    address public constant ETH_SWAP_CONFIG = 0xD504Da3Ae86Aa3233871dbc8ae3Eb38824138F7C;

    address public constant ODOS_ROUTER = 0x0D05a7D3448512B78fa8A9e46c4872C88C4a0D05;
    address public constant ZERO_X_EXCHANGE_PROXY = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        SwapConfig swapConfig = SwapConfig(ETH_SWAP_CONFIG);

        swapConfig.setApprovedSwapTarget(ODOS_ROUTER, true);
        console.log("Approved Odos Router:", ODOS_ROUTER);

        swapConfig.setApprovedSwapTarget(ZERO_X_EXCHANGE_PROXY, true);
        console.log("Approved 0x Exchange Proxy:", ZERO_X_EXCHANGE_PROXY);

        vm.stopBroadcast();

        console.log("=== Ethereum SwapConfig Routers Approved ===");
        console.log("SwapConfig:", ETH_SWAP_CONFIG);
    }
}
