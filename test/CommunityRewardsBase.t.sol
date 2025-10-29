// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {CommunityRewards} from "../src/CommunityRewards/CommunityRewards.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProtocolTimeLibrary} from "../src/libraries/ProtocolTimeLibrary.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Loan} from "../src/LoanV2.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "src/interfaces/IVoter.sol";

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

/**
 * @title CommunityRewardsBaseTest
 * @dev Comprehensive test suite for CommunityRewards contract on Base network
 */
contract CommunityRewardsBaseTest is Test {
    // Base network contract addresses
    IUSDC public usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913); // Base USDC
    IERC20 public aero = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631); // AERO token
    IVotingEscrow public votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4); // veAero
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5); // Aero Voter
    
    // Test addresses
    address public user1 = address(0x353641);
    address public user2 = address(0x26546);
    address public user3 = address(0x36546);
    address public user4 = address(0x465436);
    address public owner;
    
    // Deployed contracts
    CommunityRewards public communityRewards = CommunityRewards(0x40ac2e1401d6A80e894cA4dbeA7Ca46C6C4f9D3d);
    Loan public loan;
    uint256 public tokenId = 64196; // Existing veAero NFT on Base
    
    // Test state
    uint256 public fork;
    uint256 public constant THRESHOLD = 2500e18;
    uint256 public constant REWARD_AMOUNT = 6e6; // 6 USDC

    function setUp() public {
        // Create Base network fork
        fork = vm.createFork(vm.envString("BASE_RPC_URL"));
        vm.selectFork(fork);
        
        // Get the loan contract from the deployed CommunityRewards
        loan = Loan(communityRewards.loanContract());
        
        tokenId = communityRewards.tokenId();
        // Mock the owner for testing
        owner = loan.owner();
        vm.startPrank(owner);
        CommunityRewards commRewards = new CommunityRewards();
        communityRewards.upgradeToAndCall(address(commRewards), new bytes(0));
        vm.stopPrank();
    }

    function testClaimManagedNftCollateral() public {
        console.log("\n=== Testing Claim Managed NFT Collateral ===");
        
        // This function should only be callable by loan contract owner
        uint256 startingOwnerBalance = usdc.balanceOf(owner);
        vm.prank(owner);
        console.log("owner: %s", owner);
        communityRewards.claimManagedNftCollateral(address(votingEscrow), address(usdc));
        uint256 endingOwnerBalance = usdc.balanceOf(owner);
        // Verify that the NFT was transferred back to the owner
        assertEq(votingEscrow.ownerOf(tokenId), owner, "NFT should be transferred to owner");
        
        console.log("startingOwnerBalance: %s", startingOwnerBalance);
        console.log("endingOwnerBalance: %s", endingOwnerBalance);
        assertTrue(endingOwnerBalance > startingOwnerBalance, "Owner should have received rewards");        
        console.log("PASS Claim managed NFT collateral successful");
    }
}
