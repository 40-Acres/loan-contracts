// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Loan, VeloLoan} from "../src/VeloLoan.sol";
import {VeloLoan as LoanV2} from "../src/VeloLoanV2.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";



contract OpDeploy is Script {
    address usdc = address(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85);
    
    function run() external  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        deployLoan();
        vm.stopBroadcast();
    }

    function deployLoan() public returns (LoanV2, Vault) {
        Loan loan = new VeloLoan();
        ERC1967Proxy proxy = new ERC1967Proxy(address(loan), "");
        Vault vault = new Vault(address(usdc), address(proxy), "40op-USDC-VAULT", "40op-USDC-VAULT");
        Loan(address(proxy)).initialize(address(vault));
        address[] memory pools = new address[](4);
        pools[0] = 0x478946BcD4a5a22b316470F5486fAfb928C0bA25;
        pools[1] = 0x39eD27D101Aa4b7cE1cb4293B877954B8b5e14e5;
        pools[2] = 0xeBD5311beA1948e1441333976EadCFE5fBda777C;
        pools[3] = 0xEE1baC98527a9fDd57fcCf967817215B083cE1F0;
        uint256[] memory weights = new uint256[](4);
        weights[0] = 25e18;
        weights[1] = 25e18;
        weights[2] = 25e18;
        weights[3] = 25e18;
        console.log(Ownable2StepUpgradeable(loan).owner());
        Loan(address(proxy)).setRewardsRate(743);
        Loan(address(proxy)).setMultiplier(10);
        Loan(address(proxy)).setDefaultPools(pools, weights);
        Loan(address(proxy)).upgradeToAndCall(address(new LoanV2()), new bytes(0));
        return (LoanV2(address(proxy)), vault);
    }
}
