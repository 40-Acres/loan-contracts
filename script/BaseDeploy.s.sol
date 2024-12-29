// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Loan} from "../src/Loan.sol";
import { AerodromeVenft } from "../src/modules/base/AerodromeVenft.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";

// AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631
// VOTER = 0x16613524e02ad97edfef371bc883f2f5d6c480a5 
// VOTING ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4
// AERODROME/USDC = 0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d
// REWARDS DISTRIBUTOR = 0x227f65131a261548b057215bb1d5ab2997964c7d

contract BaseDeploy is Script {
    Loan public loan;
    AerodromeVenft public module;
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    address aero = address(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
    address usdc = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address votingEscrow = address(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    address rewardsDistributor = address(0x227f65131A261548b057215bB1D5Ab2997964C7d);
    address pool = address(0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d);

    function setUp() public {}

    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        uint256 version = 0;
        Loan loan = new Loan(address(usdc), address(pool));
        Vault vault = new Vault(address(usdc), address(loan));
        loan.setVault(address(vault));

        vm.stopBroadcast();
    }
}

