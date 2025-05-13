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
        address[] memory tokens = new address[](1);
        tokens[0] = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

        address loan = 0x87f18b377e625b62c708D5f6EA96EC193558EFD0;
        uint256 tokenId = 74706;
        address ve = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
        deploy(loan, ve, tokens, tokenId);
    }
}


contract OpDeploy is CommunityRewardsDeploy  {
    function run() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85);

        uint256 tokenId = 30882;
        address loan = 0x1eD73446Bc4Ca94002A549cf553E4Ab2f2722b42;
        address ve = 0xFAf8FD17D9840595845582fCB047DF13f006787d;
        deploy(loan, ve, tokens, tokenId);
    }
}

