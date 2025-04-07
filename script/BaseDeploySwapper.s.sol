// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {VeloLoan} from "../src/VeloLoan.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import { Swapper } from "../src/Swapper.sol";

contract DeploySwapper is Script {
    Swapper public swapper;
    address[] public supportedTokens;
    address public factory;
    address public router;
    uint256 fork;
    address _aero = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address _usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address _weth = 0x4200000000000000000000000000000000000006;

    function run() external  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        deploy();
    }

    function deploy() public returns (Swapper) {
        address[] memory _supportedTokens = new address[](3);
        _supportedTokens[0] = _aero; 
        _supportedTokens[1] = _usdc; 
        _supportedTokens[2] = _weth; 
        supportedTokens = _supportedTokens;
        
        swapper = new Swapper(
            address(0x420DD381b31aEf6683db6B902084cB0FFECe40Da),
            address(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43), 
            supportedTokens
        );
        return swapper;
    }
}
