// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Loan} from "../src/LoanV2.sol";
import {LoanV2Native} from "../src/LoanV2Native.sol";
import {IVoter} from "src/interfaces/IVoter.sol";
import {Vault} from "src/Vault.sol";

contract BaseUpgrade is Script {
    address[] pool = [address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59)];

    function run() external {
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

contract BaseUpgradeNative is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address proxy = address(0x1Dc76341CA156e376736ddbA042aba071bD3b858);
        upgradeLoan(proxy);
        vm.stopBroadcast();
    }

    function upgradeLoan(address _proxy) public {
        Loan loan = new LoanV2Native();
        Loan proxy = LoanV2Native(payable(_proxy));
        proxy.upgradeToAndCall(address(loan), new bytes(0));
    }
}

// forge script script/BaseUpgrade.s.sol:BaseUpgradeNative  --chain-id 8453 --rpc-url $BASE_RPC_URL --etherscan-api-key $BASESCAN_API_KEY --broadcast --verify --via-ir
