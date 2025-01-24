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
    Loan public loan = Loan(0xFdB2620738168e45233Ad16D62CF024ae0bC7489);
    address usdc = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);

    function setUp() public {}

    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 66852;
        tokenIds[1] = 64279;
        loan.claimRewardsMultiple(tokenIds);
        vm.stopBroadcast();
    }
}
