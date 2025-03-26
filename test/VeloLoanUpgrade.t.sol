// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/Loan.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

contract VeloLoanUpgradeTest is Test {
    uint256 fork;


    Loan public loan =
        Loan(address(0xf132bD888897254521D13e2c401e109caABa06A7));

    function setUp() public {
        fork = vm.createFork(vm.envString("OP_RPC_URL"));
        vm.selectFork(fork);
        address owner = Ownable2StepUpgradeable(address(loan)).owner();
        vm.startPrank(owner);
        Loan loanV2 = new Loan();
        loan.upgradeToAndCall(address(loanV2), new bytes(0));
        vm.stopPrank();
    }

    function testCorrect() public {
        address[] memory fees = new address[](1);
        fees[0] = address(0x3E784A33EF637314b496EDfccB03750A58214DF1);
        address[][] memory bribes = new address[][](1);
        bribes[0] = new address[](1);
        bribes[0][0] = address(0x4200000000000000000000000000000000000042);
        loan.claim(4131, fees, bribes);
    }
}