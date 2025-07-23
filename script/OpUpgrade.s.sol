// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {VeloLoan as Loan} from "../src/VeloLoanV2.sol";
import {VeloLoanNative as LoanNative} from "../src/VeloLoanV2Native.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";


contract OpUpgrade is Script {
    function run() external  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address proxy = address(0x1eD73446Bc4Ca94002A549cf553E4Ab2f2722b42);
        upgradeLoan(proxy);
        vm.stopBroadcast();
    }

    function upgradeLoan(address _proxy) public {
        Loan loan = new Loan();
        Loan proxy = Loan(payable(_proxy));
        proxy.upgradeToAndCall(address(loan), new bytes(0));
    }
}

contract OpUpgradeNative is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address proxy = address(0x8C0Ae206A52D3FddE6D43Ea5B5CbbbE00e1C0315);
        upgradeLoan(proxy);
        vm.stopBroadcast();
    }

    function upgradeLoan(address _proxy) public {
        LoanNative loan = new LoanNative();
        LoanNative proxy = LoanNative(payable(_proxy));
        proxy.upgradeToAndCall(address(loan), new bytes(0));
    }
}

// forge script script/OpUpgrade.s.sol:OpUpgradeNative  --chain-id 8453 --rpc-url $BASE_RPC_URL --etherscan-api-key $BASESCAN_API_KEY --broadcast --verify --via-ir
