// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {VeloLoan} from "../src/VeloLoan.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";


contract OpUpgrade is Script {
    function run() external  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address proxy = address(0x1eD73446Bc4Ca94002A549cf553E4Ab2f2722b42);
        upgradeLoan(proxy);
        vm.stopBroadcast();
    }

    function upgradeLoan(address _proxy) public {
        VeloLoan loan = new VeloLoan();
        VeloLoan proxy = VeloLoan(payable(_proxy));
        // proxy.upgradeToAndCall(address(loan), new bytes(0));
    }

}
