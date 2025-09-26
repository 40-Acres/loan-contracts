// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {BlackholeLoan as Loan} from "src/Blackhole/BlackholeLoan.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";
import { Vault as VaultV2 } from "src/VaultV2.sol";
// import { BlackholeSwapper as Swapper } from "../src/Blackhole/BlackholeSwapper.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BlackholeLoanV2 as LoanV2} from "../src/Blackhole/BlackholeLoanV2.sol";
import { Loan as Loanv2 } from "../src/LoanV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import { Swapper } from "../src/Swapper.sol";


contract BlackholeDeploy is Script {
    Swapper public swapper;
    address[] public supportedTokens;
    uint256 fork;
    address _bh = 0xcd94a87696FAC69Edae3a70fE5725307Ae1c43f6;
    address _asset = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
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
        VaultV2(address(vault)).initialize(address(_asset), address(_loan), "40BH-USDC-VAULT", "40BH-USDC-VAULT");

        LoanV2 loan = LoanV2(payable(_loan));
        Loan(address(loan)).initialize(address(_vault), _asset);
        LoanV2 loanV2 = new LoanV2();
        loan.upgradeToAndCall(address(loanV2), new bytes(0));
        loan.setProtocolFee(500);
        loan.setLenderPremium(2000);
        loan.setZeroBalanceFee(100);
        
        // Set default pools and weights after upgrade
        address[] memory defaultPools = new address[](1);
        defaultPools[0] = 0x000D436A430CF25c4eAaA3EFF031D2CEfdFaF4b1; // Use the working pool address
        uint256[] memory defaultWeights = new uint256[](1);
        defaultWeights[0] = 100e18;
        
        // Approve the default pool
        loan.setApprovedPools(defaultPools, true);
        // Set the default pools and weights
        loan.setDefaultPools(defaultPools, defaultWeights);

        address[] memory _supportedTokens = new address[](3);
        _supportedTokens[0] = _bh; 
        _supportedTokens[1] = _asset; 
        _supportedTokens[2] = _avax; 
        supportedTokens = _supportedTokens;
        
        // Deploy swapper with Avalanche factory and router addresses
        swapper = new Swapper(
            address(0xAAA32926fcE6bE95ea2c51cB4Fcb60836D320C42),  // factory 
            address(0xAAA45c8F5ef92a000a121d102F4e89278a711Faa), // router
            supportedTokens
        );
        loan.setSwapper(address(swapper));
        
        loan.transferOwnership(address(0x87f18b377e625b62c708D5f6EA96EC193558EFD0));
        return (loan, vault, swapper);
    }

}


contract BlackholeUpgrade is Script {
    address[] public supportedTokens;
    uint256 fork;
    address _bh = 0xcd94a87696FAC69Edae3a70fE5725307Ae1c43f6;
    address _asset = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address _avax = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

    function run() external  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        upgrade();
    }

    function upgrade() public {
        LoanV2 loanV2 = new LoanV2();
        // Loan(address(0xf6A044c3b2a3373eF2909E2474f3229f23279B5F)).upgradeToAndCall(address(loanV2), new bytes(0));
    }

}



contract BlackholeUpgradeVault is Script {
    address[] public supportedTokens;
    uint256 fork;

    function run() external  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        upgrade();
    }

    function upgrade() public {
        VaultV2 vaultV2 = new VaultV2();
        // VaultV2(address(0x124D00b1ce4453Ffc5a5F65cE83aF13A7709baC7)).upgradeToAndCall(address(vaultV2), new bytes(0));
    }

}


contract BlackholeDepositNft is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        depositNft();
    }

    function depositNft() public {
        IVoter(address(0xE30D0C8532721551a51a9FeC7FB233759964d9e3)).reset(16201);
        LoanV2(address(0x5122f5154DF20E5F29df53E633cE1ac5b6623558)).requestLoan(16201, 0, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);
    }
}
// forge script script/BlackholeDeploy.s.sol:BlackholeDeploy  --chain-id 43114 --rpc-url $AVAX_RPC_URL --etherscan-api-key $AVAXSCAN_API_KEY --broadcast --verify --via-ir
// forge script script/BlackholeDeploy.s.sol:BlackholeDepositNft  --chain-id 43114 --rpc-url $AVAX_RPC_URL --etherscan-api-key $AVAXSCAN_API_KEY --broadcast --verify --via-ir