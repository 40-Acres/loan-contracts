// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;


import {Test, console} from "forge-std/Test.sol";
import {CommunityRewards} from "../src/CommunityRewards/CommunityRewards.sol";


contract CommunityRewardsTest is Test {

    CommunityRewards public communityRewards;

    function setUp() public {
        communityRewards = new CommunityRewards();
    }

    function testCommunityRewards() public {
        // Add your test logic here
        assertTrue(true);
    }
}