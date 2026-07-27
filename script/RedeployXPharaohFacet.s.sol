// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {XPharaohFacet} from "../src/legacy/XPharaohFacet.sol";

/**
 * @dev Redeploy XPharaohFacet with _odosRouter repointed at the batch router (Odos EOL).
 *      Constructor args read off the live facet 0xef74752d...8d49. CollateralStorage
 *      auto-relinks per repo convention.
 *      The Safe then executes replaceFacet(oldFacet, newFacet, selectors, "XPharaohFacet")
 *      on the FacetRegistry 0x9bCa68D9c613Dc9B07B2727c28b5ce46204943de.
 *
 * forge script script/RedeployXPharaohFacet.s.sol:RedeployXPharaohFacet \
 *   --chain-id 43114 --rpc-url $AVAX_RPC_URL --broadcast --verify --via-ir
 */
contract RedeployXPharaohFacet is Script {
    address public constant PORTFOLIO_FACTORY = 0x52d43C377e498980135C8F2E858f120A18Ea96C2;
    address public constant ACCOUNT_CONFIG_STORAGE = 0x17cd3c65daf5b2F806d053D948Ad7d59191fd397;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        XPharaohFacet facet = new XPharaohFacet(PORTFOLIO_FACTORY, ACCOUNT_CONFIG_STORAGE);
        console.log("XPharaohFacet:", address(facet));
        vm.stopBroadcast();
    }
}
