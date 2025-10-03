// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {EtherexLoan as Loan} from "src/Etherex/EtherexLoan.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";
import { Vault as VaultV2 } from "src/VaultV2.sol";
// import { EtherexSwapper as Swapper } from "../src/Etherex/EtherexSwapper.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import { Swapper } from "../src/Swapper.sol";
import {AccountConfigStorage} from "../src/storage/AccountConfigStorage.sol";


contract EtherexDeploy is Script {
    Swapper public swapper;
    address[] public supportedTokens;
    uint256 fork;
    address _rex = 0xEfD81eeC32B9A8222D1842ec3d99c7532C31e348;
    address _asset = 0x176211869cA2b568f2A7D4EE941E073a821EE1ff;

    function run() external  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        deploy();
    }


    function deploy() public returns (Loan, Vault, Swapper, AccountConfigStorage) {
        Loan loanImplementation = new Loan();
        ERC1967Proxy _loan = new ERC1967Proxy(address(loanImplementation), "");
        VaultV2 vaultImplementation = new VaultV2();
        ERC1967Proxy _vault = new ERC1967Proxy(address(vaultImplementation), "");
        AccountConfigStorage accountConfigStorage = new AccountConfigStorage();

        Vault vault = Vault(payable(_vault));        
        VaultV2(address(vault)).initialize(address(_asset), address(_loan), "40ETHEREX-USDC-VAULT", "40ETHEREX-USDC-VAULT");

        Loan loan = Loan(payable(_loan));
        Loan(address(loan)).initialize(address(_vault), _asset);
        loan.setProtocolFee(500);
        loan.setLenderPremium(2000);
        loan.setZeroBalanceFee(100);
        
        // Set default pools and weights after upgrade
        address[] memory defaultPools = new address[](1);
        defaultPools[0] = 0x5Dc74003C0a9D08EB750B10ed5b02fA7D58d4d1e; // Use the working pool address
        uint256[] memory defaultWeights = new uint256[](1);
        defaultWeights[0] = 100e18;
        
        // Approve the default pool
        loan.setApprovedPools(defaultPools, true);
        // Set the default pools and weights
        loan.setDefaultPools(defaultPools, defaultWeights);

        address[] memory _supportedTokens = new address[](2);
        _supportedTokens[0] = _rex; 
        _supportedTokens[1] = _asset; 
        supportedTokens = _supportedTokens;
        

        
        // Deploy swapper with Avalanche factory and router addresses
        swapper = new Swapper(
            address(0x85974429677c2a701af470B82F3118e74307826e),  // factory 
            address(0xAe334f70A7FC44FCC2df9e6A37BC032497Cf80f1), // router
            supportedTokens
        );
        loan.setSwapper(address(swapper));

        loan.transferOwnership(address(0x87f18b377e625b62c708D5f6EA96EC193558EFD0));
        return (loan, vault, swapper, accountConfigStorage);
    }

}


contract EtherexUpgrade is Script {
    address[] public supportedTokens;
    uint256 fork;
    address _rex = 0xEfD81eeC32B9A8222D1842ec3d99c7532C31e348;
    address _asset = 0x176211869cA2b568f2A7D4EE941E073a821EE1ff;
    address _avax = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

    function run() external  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        // upgrade();
    }

    // function upgrade() public {
    //     Loan loanV2 = new Loan();
    //     // Loan(address(0xf6A044c3b2a3373eF2909E2474f3229f23279B5F)).upgradeToAndCall(address(loanV2), new bytes(0));
    // }

}



contract EtherexUpgradeVault is Script {
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


// forge script script/EtherexDeploy.s.sol:EtherexDeploy  --chain-id 43114 --rpc-url $AVAX_RPC_URL --etherscan-api-key $AVAXSCAN_API_KEY --broadcast --verify --via-ir
// forge script script/EtherexDeploy.s.sol:EtherexDepositNft  --chain-id 43114 --rpc-url $AVAX_RPC_URL --etherscan-api-key $AVAXSCAN_API_KEY --broadcast --verify --via-ir