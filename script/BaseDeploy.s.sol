// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Loan} from "../src/Loan.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";
import { Swapper } from "../src/Swapper.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Loan as LoanV2} from "src/LoanV2.sol";


contract BaseDeploy is Script {
    address usdc = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    
    function run() external  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        deployLoan();
        vm.stopBroadcast();
    }

    function deployLoan() public returns (LoanV2, Vault) {
        Loan loan = new Loan();
        ERC1967Proxy proxy = new ERC1967Proxy(address(loan), "");
        Vault vault = new Vault(address(usdc), address(proxy), "40op-USDC-VAULT", "40op-USDC-VAULT");
        Loan(address(proxy)).initialize(address(vault));

        LoanV2 loanV2 = new LoanV2();
        LoanV2 _proxy = LoanV2(payable(proxy));
        _proxy.upgradeToAndCall(address(loanV2), new bytes(0));

        return (LoanV2(address(proxy)), vault);
    }

}
