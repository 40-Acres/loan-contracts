// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {PharoahLoan as Loan} from "src/Pharaoh/PharoahLoan.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";
import { PharaohSwapper as Swapper } from "src/Pharaoh/PharaohSwapper.sol";
// import { PharaohSwapper as Swapper } from "../src/Pharaoh/PharaohSwapper.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PharoahLoanV2 as LoanV2} from "../src/Pharaoh/PharoahLoanV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract PharoahDeploy is Script {
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
        Loan loan = new Loan();
        ERC1967Proxy proxy = new ERC1967Proxy(address(loan), "");
        Vault vault = new Vault(address(_usdc), address(proxy));
        Loan(address(proxy)).initialize(address(vault));

        LoanV2 loanV2 = new LoanV2();
        LoanV2 _proxy = LoanV2(payable(proxy));
        _proxy.upgradeToAndCall(address(loanV2), new bytes(0));

        address[] memory _supportedTokens = new address[](3);
        _supportedTokens[0] = _phar; 
        _supportedTokens[1] = _usdc; 
        _supportedTokens[2] = _avax; 
        supportedTokens = _supportedTokens;
        
        swapper = new Swapper(
            address(0xAAA32926fcE6bE95ea2c51cB4Fcb60836D320C42),  // favtory 
            address(0xAAA45c8F5ef92a000a121d102F4e89278a711Faa), // roouter
            // address(0xAAAE99091Fbb28D400029052821653C1C752483B),
            supportedTokens
        );
        _proxy.setSwapper(address(swapper));
        return (_proxy, vault, swapper);
    }
}