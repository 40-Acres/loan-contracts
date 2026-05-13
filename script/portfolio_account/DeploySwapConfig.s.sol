// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {console} from "forge-std/console.sol";
import {SwapConfig} from "../../src/facets/account/config/SwapConfig.sol";
import {PortfolioFactoryConfigDeploy} from "./DeployPortfolioFactoryConfig.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @dev Deploy a fresh SwapConfig (impl + UUPS proxy) on the current chain.
 *      Ownership is transferred to MULTISIG_ADDRESS (inherited from
 *      PortfolioFactoryConfigDeploy); the multisig must call acceptOwnership()
 *      to finalize.
 *      Optional env: APPROVED_SWAP_TARGETS (comma-separated) seeds the approved
 *      list before the ownership handoff.
 */
contract DeploySwapConfig is PortfolioFactoryConfigDeploy {
    function run() external {
        uint256 deployerKey = vm.envUint("FORTY_ACRES_DEPLOYER");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        SwapConfig impl = new SwapConfig();
        // Initialize with deployer so we can seed approved targets in the same tx.
        SwapConfig proxy = SwapConfig(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(SwapConfig.initialize, (deployer))))
        );

        address[] memory defaultApprovedTargets = new address[](1);
        defaultApprovedTargets[0] = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;

        
        address[] memory targets = vm.envOr(
            "APPROVED_SWAP_TARGETS", ",", defaultApprovedTargets
        );

        for (uint256 i = 0; i < targets.length; i++) {
            proxy.setApprovedSwapTarget(targets[i], true);
        }

        proxy.transferOwnership(MULTISIG_ADDRESS);

        console.log("SwapConfig impl:", address(impl));
        console.log("SwapConfig proxy:", address(proxy));
        console.log("Approved targets seeded:", targets.length);
        console.log("Pending owner (must acceptOwnership()):", MULTISIG_ADDRESS);

        vm.stopBroadcast();
    }
}
