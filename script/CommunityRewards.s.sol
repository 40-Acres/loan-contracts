// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Loan} from "../src/LoanV2.sol";
import {CommunityRewards} from "../src/CommunityRewards/CommunityRewards.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";

contract CommunityRewardsDeploy is Script {
    function deploy(address loan, address ve, address[] memory tokens, uint256 tokenId) public  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        CommunityRewards _communityRewards = new CommunityRewards();

        vm.stopBroadcast();
        vm.startBroadcast(vm.envUint("VANITY_PRIVATE_KEY_1"));
        ERC1967Proxy _proxy = new ERC1967Proxy(address(_communityRewards), "");
        IVotingEscrow(ve).approve(address(_proxy), tokenId);
        CommunityRewards(address(_proxy)).initialize(address(loan), tokens, 2500e18, tokenId, ve);
        vm.stopBroadcast();
    }
}

contract BaseDeploy is CommunityRewardsDeploy {
    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        CommunityRewards _communityRewards = new CommunityRewards();
    }
}


contract OpDeploy is CommunityRewardsDeploy  {
    function run() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85);

        uint256 tokenId = 30882;
        address loan = 0xf132bD888897254521D13e2c401e109caABa06A7;
        address ve = 0xFAf8FD17D9840595845582fCB047DF13f006787d;
        deploy(loan, ve, tokens, tokenId);
    }
}


contract PharaohDeploy is CommunityRewardsDeploy  {
    function run() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);

        uint256 tokenId = 5418;
        address loan = 0xf6A044c3b2a3373eF2909E2474f3229f23279B5F;
        address ve = 0xAAAEa1fB9f3DE3F70E89f37B69Ab11B47eb9Ce6F;
        deploy(loan, ve, tokens, tokenId);
    }
}
