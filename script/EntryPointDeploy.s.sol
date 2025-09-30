// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Loan} from "../src/LoanV2.sol";
import {EntryPoint} from "../src/EntryPoint.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";

contract EntryPointDeploy is Script {
    function deploy(address loan) public  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        (bool success1,) = 0x7e20308796823AF8C82b6B7dF85ce2Ae46a1e1CF.call{value: 1229802531934816}("");
        require(success1, "First call failed");
        vm.stopBroadcast();
        vm.startBroadcast(vm.envUint("VANITY_PRIVATE_KEY_EXECUTIONER"));
        // send a empty transaction to increase the nonce
        (bool success2,) = 0x40AC2E93d1257196a418fcE7D6eDAcDE65aAf2BA.call{value: 0}("");
        require(success2, "Second call failed");
        EntryPoint _entryPoint = new EntryPoint(loan);
        vm.stopBroadcast();
    }
}

contract BaseDeploy is EntryPointDeploy {
    function run() external {
        address loan = 0x87f18b377e625b62c708D5f6EA96EC193558EFD0;
        deploy(loan);
    }   
}

contract OpDeploy is EntryPointDeploy  {
    function run() external {
        address loan = 0xf132bD888897254521D13e2c401e109caABa06A7;
        deploy(loan);
    }
}

contract PharaohDeploy is EntryPointDeploy  {
    function run() external {
        address loan = 0xf6A044c3b2a3373eF2909E2474f3229f23279B5F;
        deploy(loan);
    }
}

// forge script script/EntryPointDeploy.s.sol:PharaohDeploy --chain-id 43114 --rpc-url $AVAX_RPC_URL --etherscan-api-key $AVAXSCAN_API_KEY --broadcast --verify