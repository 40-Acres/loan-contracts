// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Loan} from "../src/Loan.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Swapper } from "../src/Swapper.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Loan as LoanV2} from "src/LoanV2.sol";
import {Vault} from "../src/VaultV2.sol";
import {LoanV2Native} from "../src/LoanV2Native.sol";

contract NativeVaultDeploy is Script {
    function deploy(address loan, address asset, string memory name, string memory symbol) public returns (LoanV2, Vault)  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        deployNative(loan, asset, name, symbol);
        vm.stopBroadcast();
    }

    function deployNative(address loan, address asset, string memory name, string memory symbol) public returns (LoanV2, Vault) {
        Loan loan = new Loan();
        ERC1967Proxy proxy = new ERC1967Proxy(address(loan), "");
        Vault vaultImplementation = new Vault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");        
        Vault vault = Vault(address(vaultProxy));
        vault.initialize(asset, address(proxy), name, symbol);
        Loan(address(proxy)).initialize(address(vault), asset);

        LoanV2Native loanV2 = new LoanV2Native();
        LoanV2Native _proxy = LoanV2Native(payable(proxy));
        _proxy.upgradeToAndCall(address(loanV2), new bytes(0));

        return (_proxy, vault);
    }
}


contract BaseDeploy is NativeVaultDeploy {
    function run() external {
        address loan = 0x87f18b377e625b62c708D5f6EA96EC193558EFD0;
        deploy(loan, 0x940181a94A35A4569E4529A3CDfB74e38FD98631, "40base-AERO-VAULT", "40base-AERO-VAULT");
    }   
}

contract OpDeploy is NativeVaultDeploy  {
    function run() external {
        address loan = 0xf132bD888897254521D13e2c401e109caABa06A7;
        deploy(loan, 0x3c8B650257cFb5f272f799F5e2b4e65093a11a05, "40op-VELO-VAULT", "40op-VELO-VAULT");
    }
}

contract PharaohDeploy is NativeVaultDeploy  {
    function run() external {
        address loan = 0xf6A044c3b2a3373eF2909E2474f3229f23279B5F;
        deploy(loan, 0xAAAB9D12A30504559b0C5a9A5977fEE4A6081c6b, "40avax-PHAR-VAULT", "40avax-PHAR-VAULT");
    }
}