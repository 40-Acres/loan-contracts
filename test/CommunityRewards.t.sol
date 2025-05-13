// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;


import {Test, console} from "forge-std/Test.sol";
import {CommunityRewards} from "../src/CommunityRewards/CommunityRewards.sol";
import{IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProtocolTimeLibrary} from "../src/libraries/ProtocolTimeLibrary.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Loan} from "../src/LoanV2.sol";
import { IVotingEscrow } from "../src/interfaces/IVotingEscrow.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import {ICLGauge} from "src/interfaces/ICLGauge.sol";
import {OpDeploy} from "../script/CommunityRewards.s.sol";

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

    CommunityRewards public communityRewards;
    IUSDC public usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address public user1 = address(0x353641);
    address public user2 = address(0x26546);
    address public user3 = address(0x36546);
    address public user4 = address(0x465436);
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);

    Loan public loan = Loan(address(0x87f18b377e625b62c708D5f6EA96EC193558EFD0));
    uint256 public tokenId = 524;

    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);

    function setUp() public {
        uint256 fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);


        address user = votingEscrow.ownerOf(tokenId);
        vm.prank(user);
        votingEscrow.transferFrom(user, address(this), tokenId);

        CommunityRewards _communityRewards = new CommunityRewards();
        ERC1967Proxy _proxy = new ERC1967Proxy(address(_communityRewards), "");
        votingEscrow.approve(address(_proxy), tokenId);
        vm.roll(block.number + 1);
        CommunityRewards(address(_proxy)).initialize(address(loan), tokens, 2500e18, tokenId, 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);


        communityRewards = CommunityRewards(address(_proxy));
              
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(loan), 150e18);

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

    function testUpgrade() public {
        vm.startPrank(IOwnable(address(loan)).owner());
        address newImplementation = address(new CommunityRewards());
        communityRewards.upgradeToAndCall(newImplementation, new bytes(0));
        vm.stopPrank();
        vm.expectRevert();
        communityRewards.upgradeToAndCall(newImplementation, new bytes(0));

    }
    
    function testCommunityRewards() public {
        vm.startPrank(address(loan));
        communityRewards.deposit(tokenId, 1e18, user1);
        communityRewards.deposit(tokenId, 1e18, user2);
        communityRewards.deposit(tokenId, 1e18, user3);
        communityRewards.deposit(tokenId, 1e18, user4);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);
        usdc.approve(address(communityRewards), type(uint256).max);
        vm.startPrank(address(loan));
        usdc.transfer(address(communityRewards), 6e6);
        communityRewards.notifyRewardAmount(address(usdc), 6e6);
        vm.stopPrank();


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


    function testThreshold() public {
        vm.startPrank(address(loan));
        communityRewards.deposit(uint256(1), 1000e18, user1);
        communityRewards.deposit(tokenId, 1e18, user2);
        communityRewards.deposit(tokenId, 1e18, user3);
        communityRewards.deposit(tokenId, 1e18, user4);
        vm.stopPrank();

        console.log("balance", usdc.balanceOf(user1));
        vm.warp(block.timestamp + 7 days);
        usdc.approve(address(communityRewards), type(uint256).max);
        vm.startPrank(address(loan));
        usdc.transfer(address(communityRewards), 6e6);
        communityRewards.notifyRewardAmount(address(usdc), 6e6);
        vm.stopPrank();


        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        vm.prank(user1);
        communityRewards.getReward(tokens);

        assertEq(usdc.balanceOf(user1), 0e6, "User 1 should have received 0 USDC");
    }

    function testMeetThresholdNoFlightReward() public {
        vm.startPrank(address(loan));
        communityRewards.deposit(uint256(1), 3000e18, user1);
        communityRewards.deposit(tokenId, 1e18, user2);
        communityRewards.deposit(tokenId, 1e18, user3);
        communityRewards.deposit(tokenId, 1e18, user4);
        vm.stopPrank();

        console.log("balance", usdc.balanceOf(user1));
        vm.warp(block.timestamp + 7 days);
        usdc.approve(address(communityRewards), type(uint256).max);
        vm.startPrank(address(loan));
        usdc.transfer(address(communityRewards), 6e6);
        communityRewards.notifyRewardAmount(address(usdc), 6e6);
        vm.stopPrank();


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
        assertEq(usdc.balanceOf(user2), 2e6, "User 2 should have received 2 USDC");
        assertEq(usdc.balanceOf(user3), 2e6, "User 3 should have received 2 USDC");
        assertEq(usdc.balanceOf(user4), 2e6, "User 4 should have received 2 USDC");

    }

    function testIncrease() public {
        vm.startPrank(address(loan));
        communityRewards.deposit(tokenId, 1e18, user1);
        communityRewards.deposit(tokenId, 1e18, user2);
        communityRewards.deposit(tokenId, 1e18, user3);
        communityRewards.deposit(tokenId, 1e18, user4);
        vm.stopPrank();

        console.log("balance", usdc.balanceOf(user1));
        vm.warp(block.timestamp + 7 days);
        vm.prank(address(loan));
        communityRewards.deposit(tokenId, 1e18, user4);
        usdc.approve(address(communityRewards), type(uint256).max);
        vm.startPrank(address(loan));
        usdc.transfer(address(communityRewards), 6e6);
        communityRewards.notifyRewardAmount(address(usdc), 6e6);
        vm.stopPrank();


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
        vm.startPrank(address(loan));
        communityRewards.deposit(tokenId, 1e18, user1);
        communityRewards.deposit(tokenId, 1e18, user2);
        communityRewards.deposit(tokenId, 1e18, user3);
        communityRewards.deposit(tokenId, 1e18, user4);
        vm.stopPrank();

        vm.prank(user1);
        communityRewards.transfer(user2, 1e18);

        vm.warp(block.timestamp + 7 days);
        usdc.approve(address(communityRewards), type(uint256).max);
        vm.startPrank(address(loan));
        usdc.transfer(address(communityRewards), 6e6);
        communityRewards.notifyRewardAmount(address(usdc), 6e6);
        vm.stopPrank();

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
        vm.startPrank(address(loan));
        communityRewards.deposit(tokenId, 1e18, user1);
        communityRewards.deposit(tokenId, 1e18, user2);
        communityRewards.deposit(tokenId, 1e18, user3);
        communityRewards.deposit(tokenId, 1e18, user4);
        vm.stopPrank();

        vm.prank(user1);
        communityRewards.transfer(user2, 1e18);

        vm.warp(block.timestamp + 7 days);
        vm.prank(user2);
        communityRewards.transfer(user1, 1e18);
        usdc.approve(address(communityRewards), type(uint256).max);
        vm.startPrank(address(loan));
        usdc.transfer(address(communityRewards), 6e6);
        communityRewards.notifyRewardAmount(address(usdc), 6e6);
        vm.stopPrank();

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
        vm.startPrank(address(loan));
        communityRewards.deposit(tokenId, 1e18, user1);
        communityRewards.deposit(tokenId, 1e18, user2);
        communityRewards.deposit(tokenId, 1e18, user3);
        communityRewards.deposit(tokenId, 1e18, user4);
        vm.stopPrank();

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        
        vm.warp(block.timestamp + 7 days);
        usdc.approve(address(communityRewards), type(uint256).max);
        vm.prank(user1);
        communityRewards.getReward(tokens);
        vm.startPrank(address(loan));
        usdc.transfer(address(communityRewards), 6e6);
        communityRewards.notifyRewardAmount(address(usdc), 6e6);
        vm.stopPrank();

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
        vm.startPrank(address(loan));
        communityRewards.deposit(tokenId, 1e18, user1);
        communityRewards.deposit(tokenId, 1e18, user2);
        communityRewards.deposit(tokenId, 1e18, user3);
        communityRewards.deposit(tokenId, 1e18, user4);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);
        usdc.approve(address(communityRewards), type(uint256).max);
        vm.startPrank(address(loan));
        usdc.transfer(address(communityRewards), 6e6);
        communityRewards.notifyRewardAmount(address(usdc), 6e6);
        vm.stopPrank();

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        vm.prank(user2);
        communityRewards.getReward(tokens);
        vm.prank(user3);
        communityRewards.getReward(tokens);
        vm.prank(user4);
        communityRewards.getReward(tokens);


        vm.startPrank(address(loan));
        usdc.transfer(address(communityRewards), 6e6);
        communityRewards.notifyRewardAmount(address(usdc), 6e6);
        vm.stopPrank();

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


        vm.startPrank(address(loan));
        usdc.transfer(address(communityRewards), 6e6);
        communityRewards.notifyRewardAmount(address(usdc), 6e6);
        vm.stopPrank();

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

    function testFlightSchoolAllocation() public {
        vm.startPrank(address(loan));
        communityRewards.deposit(tokenId, 1e18, user1);
        communityRewards.deposit(tokenId, 1e18, user2);
        communityRewards.deposit(tokenId, 1e18, user3);
        communityRewards.deposit(uint256(1), 1e18, user4);
        vm.stopPrank();

        vm.warp(block.timestamp + 3 days);
        uint256 currentFlight = ProtocolTimeLibrary.epochStart(block.timestamp) - ProtocolTimeLibrary.epochStart(block.timestamp) % (4*ProtocolTimeLibrary.WEEK);
        uint256 flightDeposits = communityRewards.flightDeposits(user1, currentFlight);
        assertEq(flightDeposits, 1e18, "User 1 should have 1e18 flight deposits");
        vm.warp(block.timestamp + 28 days);
        flightDeposits = communityRewards.flightDeposits(user1, ProtocolTimeLibrary.epochStart(block.timestamp) - ProtocolTimeLibrary.epochStart(block.timestamp) % (4*ProtocolTimeLibrary.WEEK));
        assertEq(flightDeposits, 0, "User 1 should have 0e18 flight deposits");



        uint256 balance = IERC20(address(communityRewards)).balanceOf(user1);
        assertEq(balance, 1e18, "User 1 should have 1e18 balance");


        balance = IERC20(address(communityRewards)).balanceOf(user4);
        assertEq(balance, 0, "User 4 should have 0 balance");

        vm.startPrank(address(loan));
        communityRewards.notifyFlightBonus(.75e18);
        vm.stopPrank();

        communityRewards.claimFlightBonus(address(user1), currentFlight);
        balance = IERC20(address(communityRewards)).balanceOf(user1);
        assertEq(balance, 1e18 + .25e18, "User 1 should have 1.25e18 balance");

        communityRewards.claimFlightBonus(address(user2), currentFlight);
        balance = IERC20(address(communityRewards)).balanceOf(user2);
        assertEq(balance, 1e18 + .25e18, "User 2 should have 1.25e18 balance");

        communityRewards.claimFlightBonus(address(user3), currentFlight);
        balance = IERC20(address(communityRewards)).balanceOf(user3);
        assertEq(balance, 1e18 + .25e18, "User 3 should have 1.25e18 balance");

        communityRewards.claimFlightBonus(address(user4), currentFlight);
        balance = IERC20(address(communityRewards)).balanceOf(user4);
        assertEq(balance, 0, "User 4  should have 0 balance");
    }

    function testFlightSchoolEscrowAllocation() public {
        vm.startPrank(address(loan));
        communityRewards.deposit(tokenId, 1000e18, user1);
        communityRewards.deposit(tokenId, 1000e18, user2);
        communityRewards.deposit(tokenId, 1000e18, user3);
        communityRewards.deposit(uint256(1), 3000e18, user4);
        vm.stopPrank();

        vm.warp(block.timestamp + 3 days);
        uint256 currentFlight = ProtocolTimeLibrary.epochStart(block.timestamp) - ProtocolTimeLibrary.epochStart(block.timestamp) % (4*ProtocolTimeLibrary.WEEK);
        uint256 flightDeposits = communityRewards.flightDeposits(user1, currentFlight);
        assertEq(flightDeposits, 1000e18, "User 1 should have 1000e18 flight deposits");


        uint256 balance = IERC20(address(communityRewards)).balanceOf(user1);
        assertEq(balance, 1000e18, "User 1 should have 1000e18 balance");


        balance = IERC20(address(communityRewards)).balanceOf(user4);
        assertEq(balance, 0, "User 4 should have 0 balance");

        vm.warp(block.timestamp + 28 days);
        vm.startPrank(address(loan));
        communityRewards.notifyFlightBonus(600e18);
        vm.stopPrank();
        communityRewards.claimFlightBonus(address(user1), currentFlight);
        balance = IERC20(address(communityRewards)).balanceOf(user1);
        assertEq(balance, 1000e18 + 100e18, "User 1 should have 1100e18 balance");

        communityRewards.claimFlightBonus(address(user2), currentFlight);
        balance = IERC20(address(communityRewards)).balanceOf(user2);
        assertEq(balance, 1000e18 + 100e18, "User 2 should have 1100e18 balance");

        communityRewards.claimFlightBonus(address(user3), currentFlight);
        balance = IERC20(address(communityRewards)).balanceOf(user3);
        assertEq(balance, 1000e18 + 100e18, "User 3 should have 1100e18 balance");

        communityRewards.claimFlightBonus(address(user4), currentFlight);
        balance = IERC20(address(communityRewards)).balanceOf(user4);
        assertEq(balance, 300e18, "User 4 should have 300e18 balance");
    }


    function _claimRewards(Loan _loan, uint256 _tokenId, address[] memory bribes) internal returns (uint256) {
        address[] memory pools = new address[](256); // Assuming a maximum of 256 pool votes
        uint256 index = 0;

        while (true) {
            try voter.poolVote(_tokenId, index) returns (address _pool) {
                pools[index] = _pool;
                index++;
            } catch {
                break; // Exit the loop when it reverts
            }
        }

        address[] memory voterPools = new address[](index);
        for (uint256 i = 0; i < index; i++) {
            voterPools[i] = pools[i];
        }
        address[] memory fees = new address[](2 * voterPools.length);
        address[][] memory tokens = new address[][](2 * voterPools.length);

        for (uint256 i = 0; i < voterPools.length; i++) {
            address gauge = voter.gauges(voterPools[i]);
            fees[2 * i] = voter.gaugeToFees(gauge);
            fees[2 * i + 1] = voter.gaugeToBribe(gauge);
            address[] memory token = new address[](2);
            token[0] = ICLGauge(voterPools[i]).token0();
            token[1] = ICLGauge(voterPools[i]).token1();
            tokens[2 * i] = token;
            address[] memory bribeTokens = new address[](bribes.length + 2);
            for (uint256 j = 0; j < bribes.length; j++) {
                bribeTokens[j] = bribes[j];
            }
            bribeTokens[bribes.length] = token[0];
            bribeTokens[bribes.length + 1] = token[1];
            tokens[2 * i + 1] = bribeTokens;
        }
        return _loan.claim(_tokenId, fees, tokens);
    }
}