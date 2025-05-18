// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {PharaohLoan as Loan} from "src/Pharaoh/PharaohLoan.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";
import { Vault as VaultV2 } from "src/VaultV2.sol";
import { PharaohSwapper as Swapper } from "src/Pharaoh/PharaohSwapper.sol";
// import { PharaohSwapper as Swapper } from "../src/Pharaoh/PharaohSwapper.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PharaohLoanV2 as LoanV2} from "../src/Pharaoh/PharaohLoanV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract PharaohDeploy is Script {
    Swapper public swapper;
    address[] public supportedTokens;
    uint256 fork;
    address _phar = 0xAAAB9D12A30504559b0C5a9A5977fEE4A6081c6b;
    address _usdc = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address _avax = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

    function run() external  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        deploy();
    }

    function deploy() public returns (LoanV2, Vault, Swapper) {
        Loan loanImplementation = new Loan();
        ERC1967Proxy _loan = new ERC1967Proxy(address(loanImplementation), "");
        VaultV2 vaultImplementation = new VaultV2();
        ERC1967Proxy _vault = new ERC1967Proxy(address(vaultImplementation), "");

        Vault vault = Vault(payable(_vault));
        LoanV2 loan = LoanV2(payable(_loan));
        Loan(address(loan)).initialize(address(_vault));
        VaultV2(address(vault)).initialize(address(_usdc), address(loan), "40avax-USDC-VAULT", "40avax-USDC-VAULT");
        LoanV2 loanV2 = new LoanV2();
        loan.upgradeToAndCall(address(loanV2), new bytes(0));
        loan.setProtocolFee(500);
        loan.setLenderPremium(2000);
        loan.setZeroBalanceFee(100);

        address[] memory _supportedTokens = new address[](3);
        _supportedTokens[0] = _phar; 
        _supportedTokens[1] = _usdc; 
        _supportedTokens[2] = _avax; 
        supportedTokens = _supportedTokens;
        
        swapper = new Swapper(
            address(0xAAA32926fcE6bE95ea2c51cB4Fcb60836D320C42),  // favtory 
            address(0xAAA45c8F5ef92a000a121d102F4e89278a711Faa), // router
            supportedTokens
        );
        loan.setSwapper(address(swapper));
        loan.transferOwnership(address(0x87f18b377e625b62c708D5f6EA96EC193558EFD0));
        return (loan, vault, swapper);
    }
}