// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Loan} from "../src/VeloLoan.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";
import { RateCalculator } from "src/RateCalculator.sol";


contract OpUpgrade is Script {
    function run() external  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address proxy = address(0x87f18b377e625b62c708D5f6EA96EC193558EFD0);
        upgradeLoan(proxy);
        vm.stopBroadcast();
    }

    function upgradeLoan(address _proxy) public {
        Loan loan = new Loan();
        Loan proxy = Loan(payable(_proxy));
        proxy.upgradeToAndCall(address(loan), new bytes(0));
    }

}
