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
    address _op = address(0x4200000000000000000000000000000000000042);
    address _weth = address(0x4200000000000000000000000000000000000006);
    address _usdc = address(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85);

    function run() external  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        deploy();
    }

    function deploy() public returns (Swapper) {
        address[] memory _supportedTokens = new address[](3);
        _supportedTokens[0] = _op; 
        _supportedTokens[1] = _usdc; 
        _supportedTokens[2] = _weth; 
        supportedTokens = _supportedTokens;
        
        swapper = new Swapper(
            address(0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a),
            address(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858), 
            supportedTokens
        );
        return swapper;
    }
}
