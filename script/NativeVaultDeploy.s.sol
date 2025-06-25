// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Loan} from "../src/LoanV2.sol";
import {EntryPoint} from "../src/EntryPoint.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";
import {Vault} from "../src/VaultV2.sol";
contract EntryPointDeploy is Script {
    function deploy(address loan, address asset, string memory name, string memory symbol) public  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        vm.stopBroadcast();
    }
}

contract BaseDeploy is EntryPointDeploy {
    function run() external {
        address loan = 0x87f18b377e625b62c708D5f6EA96EC193558EFD0;
        deploy(loan, 0x940181a94A35A4569E4529A3CDfB74e38FD98631, "40base-AERO-VAULT", "40base-AERO-VAULT");
    }   
}

contract OpDeploy is EntryPointDeploy  {
    function run() external {
        address loan = 0xf132bD888897254521D13e2c401e109caABa06A7;
        deploy(loan, 0x3c8B650257cFb5f272f799F5e2b4e65093a11a05, "40op-VELO-VAULT", "40op-VELO-VAULT");
    }
}

contract PharaohDeploy is EntryPointDeploy  {
    function run() external {
        address loan = 0xf6A044c3b2a3373eF2909E2474f3229f23279B5F;
        deploy(loan, 0xAAAB9D12A30504559b0C5a9A5977fEE4A6081c6b, "40avax-PHAR-VAULT", "40avax-PHAR-VAULT");
        deploy(loan, 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E, "40avax-USDC-VAULT", "40avax-USDC-VAULT");
    }
}