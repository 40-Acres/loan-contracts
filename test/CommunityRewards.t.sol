// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;


import {Test, console} from "forge-std/Test.sol";
import {CommunityRewards} from "../src/CommunityRewards/CommunityRewards.sol";
import{IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(address minter, uint256 minterAllowedAmount) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address) external;
    function acceptOwnership() external;
}


contract CommunityRewardsTest is Test {
    uint256 fork;

    CommunityRewards public communityRewards;
    IUSDC public usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address public user1 = address(0x353641);
    address public user2 = address(0x26546);
    address public user3 = address(0x36546);
    address public user4 = address(0x465436);

    function setUp() public {
        fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        communityRewards = new CommunityRewards(address(this), tokens, 1000);
              
        IERC20 aero = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(this), 150e18);

        // remove all users usdc balance
        vm.prank(user1);
        usdc.transfer(address(this), usdc.balanceOf(user1));
        vm.prank(user2);
        usdc.transfer(address(this), usdc.balanceOf(user2));
        vm.prank(user3);
        usdc.transfer(address(this), usdc.balanceOf(user3));
        vm.prank(user4);
        usdc.transfer(address(this), usdc.balanceOf(user4));
    }

    function testCommunityRewards() public {
        communityRewards.deposit(uint256(0), 1e18, user1);
        communityRewards.deposit(uint256(0), 1e18, user2);
        communityRewards.deposit(uint256(0), 1e18, user3);
        communityRewards.deposit(uint256(0), 1e18, user4);

        console.log("balance", usdc.balanceOf(user1));
        vm.warp(block.timestamp + 7 days);
        usdc.approve(address(communityRewards), type(uint256).max);
        communityRewards.notifyRewardAmount(address(usdc), 6e6);


        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        vm.prank(user1);
        communityRewards.getReward(tokens);
        vm.prank(user2);
        communityRewards.getReward(tokens);
        vm.prank(user3);
        communityRewards.getReward(tokens);
        vm.prank(user4);
        communityRewards.getReward(tokens);

        assertEq(usdc.balanceOf(user1), 1.5e6, "User 1 should have received 1.5 USDC");
        assertEq(usdc.balanceOf(user2), 1.5e6, "User 2 should have received 1.5 USDC");
        assertEq(usdc.balanceOf(user3), 1.5e6, "User 3 should have received 1.5 USDC");
        assertEq(usdc.balanceOf(user4), 1.5e6, "User 4 should have received 1.5 USDC");
    }



    function testIncrease() public {
        communityRewards.deposit(uint256(0), 1e18, user1);
        communityRewards.deposit(uint256(0), 1e18, user2);
        communityRewards.deposit(uint256(0), 1e18, user3);
        communityRewards.deposit(uint256(0), 1e18, user4);

        console.log("balance", usdc.balanceOf(user1));
        vm.warp(block.timestamp + 7 days);
        communityRewards.deposit(uint256(0), 1e18, user4);
        usdc.approve(address(communityRewards), type(uint256).max);
        communityRewards.notifyRewardAmount(address(usdc), 6e6);


        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        vm.prank(user1);
        communityRewards.getReward(tokens);
        vm.prank(user2);
        communityRewards.getReward(tokens);
        vm.prank(user3);
        communityRewards.getReward(tokens);
        vm.prank(user4);
        communityRewards.getReward(tokens);

        assertEq(usdc.balanceOf(user1), 1.5e6, "User 1 should have received 1.5 USDC");
        assertEq(usdc.balanceOf(user2), 1.5e6, "User 2 should have received 1.5 USDC");
        assertEq(usdc.balanceOf(user3), 1.5e6, "User 3 should have received 1.5 USDC");
        assertEq(usdc.balanceOf(user4), 1.5e6, "User 4 should have received 1.5 USDC");
    }



    function testTransfer() public {
        communityRewards.deposit(uint256(0), 1e18, user1);
        communityRewards.deposit(uint256(0), 1e18, user2);
        communityRewards.deposit(uint256(0), 1e18, user3);
        communityRewards.deposit(uint256(0), 1e18, user4);

        vm.prank(user1);
        communityRewards.transfer(user2, 1e18);

        vm.warp(block.timestamp + 7 days);
        usdc.approve(address(communityRewards), type(uint256).max);
        communityRewards.notifyRewardAmount(address(usdc), 6e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        vm.prank(user1);
        communityRewards.getReward(tokens);
        vm.prank(user2);
        communityRewards.getReward(tokens);
        vm.prank(user3);
        communityRewards.getReward(tokens);
        vm.prank(user4);
        communityRewards.getReward(tokens);

        assertEq(usdc.balanceOf(user1), 0, "User 1 should have received 0 USDC");
        assertEq(usdc.balanceOf(user2), 3e6, "User 2 should have received 3 USDC");
        assertEq(usdc.balanceOf(user3), 1.5e6, "User 3 should have received 1.5 USDC");
        assertEq(usdc.balanceOf(user4), 1.5e6, "User 4 should have received 1.5 USDC");
    }


    function testTransfer2() public {
        communityRewards.deposit(uint256(0), 1e18, user1);
        communityRewards.deposit(uint256(0), 1e18, user2);
        communityRewards.deposit(uint256(0), 1e18, user3);
        communityRewards.deposit(uint256(0), 1e18, user4);

        vm.prank(user1);
        communityRewards.transfer(user2, 1e18);

        vm.warp(block.timestamp + 7 days);
        vm.prank(user2);
        communityRewards.transfer(user1, 1e18);
        usdc.approve(address(communityRewards), type(uint256).max);
        communityRewards.notifyRewardAmount(address(usdc), 6e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        vm.prank(user1);
        communityRewards.getReward(tokens);
        vm.prank(user2);
        communityRewards.getReward(tokens);
        vm.prank(user3);
        communityRewards.getReward(tokens);
        vm.prank(user4);
        communityRewards.getReward(tokens);

        assertEq(usdc.balanceOf(user1), 0, "User 1 should have received 0 USDC");
        assertEq(usdc.balanceOf(user2), 3e6, "User 2 should have received 3 USDC");
        assertEq(usdc.balanceOf(user3), 1.5e6, "User 3 should have received 1.5 USDC");
        assertEq(usdc.balanceOf(user4), 1.5e6, "User 4 should have received 1.5 USDC");
    }

    function testClaimSameEpochBeforeRewardsReceived() public {
        communityRewards.deposit(uint256(0), 1e18, user1);
        communityRewards.deposit(uint256(0), 1e18, user2);
        communityRewards.deposit(uint256(0), 1e18, user3);
        communityRewards.deposit(uint256(0), 1e18, user4);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        
        vm.warp(block.timestamp + 7 days);
        usdc.approve(address(communityRewards), type(uint256).max);
        vm.prank(user1);
        communityRewards.getReward(tokens);
        communityRewards.notifyRewardAmount(address(usdc), 6e6);

        vm.prank(user1);
        communityRewards.getReward(tokens);
        vm.prank(user2);
        communityRewards.getReward(tokens);
        vm.prank(user3);
        communityRewards.getReward(tokens);
        vm.prank(user4);
        communityRewards.getReward(tokens);

        assertEq(usdc.balanceOf(user1), 1.5e6, "User 1 should have received 1.5 USDC");
        assertEq(usdc.balanceOf(user2), 1.5e6, "User 2 should have received 1.5 USDC");
        assertEq(usdc.balanceOf(user3), 1.5e6, "User 3 should have received 1.5 USDC");
        assertEq(usdc.balanceOf(user4), 1.5e6, "User 4 should have received 1.5 USDC");
    }
    function testRewardsReceivedAfterClaim() public {
        communityRewards.deposit(uint256(0), 1e18, user1);
        communityRewards.deposit(uint256(0), 1e18, user2);
        communityRewards.deposit(uint256(0), 1e18, user3);
        communityRewards.deposit(uint256(0), 1e18, user4);

        vm.warp(block.timestamp + 7 days);
        usdc.approve(address(communityRewards), type(uint256).max);
        communityRewards.notifyRewardAmount(address(usdc), 6e6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        vm.prank(user2);
        communityRewards.getReward(tokens);
        vm.prank(user3);
        communityRewards.getReward(tokens);
        vm.prank(user4);
        communityRewards.getReward(tokens);


        communityRewards.notifyRewardAmount(address(usdc), 6e6);

        vm.prank(user1);
        communityRewards.getReward(tokens);
        vm.prank(user2);
        communityRewards.getReward(tokens);
        
        vm.prank(user4);
        communityRewards.getReward(tokens);


        assertEq(usdc.balanceOf(user1), 3e6, "User 1 should have received 3 USDC");
        assertEq(usdc.balanceOf(user2), 3e6, "User 2 should have received 3 USDC");
        assertEq(usdc.balanceOf(user3), 1.5e6, "User 3 should have received 1.5 USDC");
        assertEq(usdc.balanceOf(user4), 3e6, "User 4 should have received 3 USDC");


        communityRewards.notifyRewardAmount(address(usdc), 6e6);

        vm.prank(user1);
        communityRewards.getReward(tokens);
        vm.prank(user2);
        communityRewards.getReward(tokens);
        vm.prank(user3);
        communityRewards.getReward(tokens);
        vm.prank(user4);
        communityRewards.getReward(tokens);


        assertEq(usdc.balanceOf(user1), 4.5e6, "User 1 should have received 4.5 USDC");
        assertEq(usdc.balanceOf(user2), 4.5e6, "User 2 should have received 4.5 USDC");
        assertEq(usdc.balanceOf(user3), 4.5e6, "User 3 should have received 4.5 USDC");
        assertEq(usdc.balanceOf(user4), 4.5e6, "User 4 should have received 4.5 USDC");


        vm.prank(user1);
        communityRewards.getReward(tokens);
        vm.prank(user2);
        communityRewards.getReward(tokens);
        vm.prank(user3);
        communityRewards.getReward(tokens);
        vm.prank(user4);
        communityRewards.getReward(tokens);



        assertEq(usdc.balanceOf(user1), 4.5e6, "User 1 should have received 4.5 USDC");
        assertEq(usdc.balanceOf(user2), 4.5e6, "User 2 should have received 4.5 USDC");
        assertEq(usdc.balanceOf(user3), 4.5e6, "User 3 should have received 4.5 USDC");
        assertEq(usdc.balanceOf(user4), 4.5e6, "User 4 should have received 4.5 USDC");

    }
    
}