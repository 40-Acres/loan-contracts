// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Loan} from "../src/Loan.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";
import { RateCalculator } from "src/RateCalculator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotingEscrow } from "../src/interfaces/IVotingEscrow.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

// AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631
// VOTER = 0x16613524e02ad97edfef371bc883f2f5d6c480a5 
// VOTING ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4
// AERODROME/USDC = 0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d
// REWARDS DISTRIBUTOR = 0x227f65131a261548b057215bb1d5ab2997964c7d

contract AdvanceLoan is Script {
    Loan public loan = Loan(0x87f18b377e625b62c708D5f6EA96EC193558EFD0);
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);

    function setUp() public {}
    
    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = 64196;
        // tokenIds[1] = 68509;
        // tokenIds[2] = 68510;
        loan.claimCollateral(tokenIds[0]);
        vm.stopBroadcast();
    }
}
