// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Loan, VeloLoan} from "../src/VeloLoan.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";
import { RateCalculator } from "src/RateCalculator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";


contract OpDeploy is Script {
    address usdc = address(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85);
    
    function run() external  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        deployLoan();
        vm.stopBroadcast();
    }

    function deployLoan() public returns (Loan, Vault, RateCalculator) {
        Loan loan = new VeloLoan();
        ERC1967Proxy proxy = new ERC1967Proxy(address(loan), "");
        Vault vault = new Vault(address(usdc), address(proxy));
        Loan(address(proxy)).initialize(address(vault));
        console.log(Loan(address(proxy)).owner());
        RateCalculator rateCalculator = new RateCalculator(address(proxy));
        Loan(address(proxy)).setRateCalculator(address(rateCalculator));
        return (Loan(address(proxy)), vault, rateCalculator);
    }
}
