// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {BlackholeRebaseHelper} from "../src/Blackhole/BlackholeRebaseHelper.sol";

contract BlackholeClaimRebase is Script {
    BlackholeRebaseHelper constant HELPER = BlackholeRebaseHelper(0x87D0F8C19a891c13C85185d8Ba71Ab1a419bDe0C);
    uint256 constant BATCH_SIZE = 20;

    function run() external {
        // Scan off-chain (view call, no gas)
        uint256 startIndex = 0;

        uint256[] memory batch = HELPER.scan(startIndex, BATCH_SIZE);
        if (batch.length == 0) return;
        console.log(batch.length);
        // Broadcast the claim tx
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        HELPER.claim(batch);
        vm.stopBroadcast();
    }
}

// forge script script/BlackholeClaimRebase.s.sol:BlackholeClaimRebase --chain-id 43114 --rpc-url $AVAX_RPC_URL --broadcast --via-ir
