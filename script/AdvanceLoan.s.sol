// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Loan} from "../src/Loan.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";
import { RateCalculator } from "src/RateCalculator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631
// VOTER = 0x16613524e02ad97edfef371bc883f2f5d6c480a5 
// VOTING ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4
// AERODROME/USDC = 0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d
// REWARDS DISTRIBUTOR = 0x227f65131a261548b057215bb1d5ab2997964c7d

contract AdvanceLoan is Script {
    Loan public loan = Loan(0x25244fE81803C8135dFd37Ee5540B2A39C2B9553);
    address usdc = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    function setUp() public {}

    function run() public {
        address[] memory zeropools = new address[](0);
        address[] memory onepool = new address[](1);
        onepool[0] = address(0xFAD14c545E464e04c737d00643296144eb20c7F8);
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        loan.requestLoan(68509, 0, onepool, Loan.ZeroBalanceOption.InvestToVault);
        loan.requestLoan(68510, 0, zeropools, Loan.ZeroBalanceOption.PayToOwner);


        vm.stopBroadcast();
    }
}
