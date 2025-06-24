// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotingEscrow } from "../src/interfaces/IVotingEscrow.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ProtocolTimeLibrary } from "src/libraries/ProtocolTimeLibrary.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {PharaohDeploy} from "../script/PharaohDeploy.s.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ICLGauge} from "src/interfaces/ICLGauge.sol";
// import { PharaohSwapper as Swapper } from "../src/Pharaoh/PharaohSwapper.sol";
import { PharaohSwapper as Swapper } from "../src/Pharaoh/PharaohSwapper.sol";
import {CommunityRewards} from "../src/CommunityRewards/CommunityRewards.sol";
import { IMinter } from "src/interfaces/IMinter.sol";

import {PharaohLoanV2 as Loan} from "../src/Pharaoh/PharaohLoanV2.sol";
import { Loan as Loanv2 } from "../src/LoanV2.sol";

interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(address minter, uint256 minterAllowedAmount) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);

}
interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address) external;
    function acceptOwnership() external;
}


contract PharaohLoanTest is Test {
    uint256 fork;
    uint256 fork2;
    uint256 _fork = vm.createFork(vm.envString("AVAX_RPC_URL"));
    IERC20 aero = IERC20(0xAAAB9D12A30504559b0C5a9A5977fEE4A6081c6b);
    IUSDC usdc = IUSDC(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);
    IVotingEscrow votingEscrow = IVotingEscrow(0xAAAEa1fB9f3DE3F70E89f37B69Ab11B47eb9Ce6F);
    IERC20 weth = IERC20(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    IVoter public voter = IVoter(0xAAAf3D9CDD3602d117c67D80eEC37a160C8d9869);
    address[] pool = [address(0x1a2950978E29C5e590C77B0b6247beDbFB0b4185)];
    ProxyAdmin admin;

    // deployed contracts
    Vault vault;
    Loan public loan;
    Swapper public swapper;
    address owner;
    address user;
    uint256 tokenId = 3801;

    uint256 expectedRewards = 1269895;

    function setUp() public {
        fork = vm.createFork(vm.envString("AVAX_RPC_URL"));
        fork2 = vm.createFork(vm.envString("AVAX_RPC_URL"));
        vm.selectFork(fork2);
        vm.rollFork(62047585);
        vm.selectFork(_fork);
        vm.rollFork(64204517);
        vm.selectFork(fork);
        vm.rollFork(62112514);
        owner = vm.addr(0x123);
        user = votingEscrow.ownerOf(tokenId);
        console.log("user", user);
        PharaohDeploy deployer = new PharaohDeploy();
        (loan, vault, swapper) = deployer.deploy();

        vm.startPrank(address(deployer));
        loan.setMultiplier(100000000000);
        loan.setRewardsRate(11300);
        loan.setLenderPremium(2000);
        loan.setProtocolFee(500); // 5% protocol fee
        IOwnable(address(loan)).transferOwnership(owner);
        vm.stopPrank();

        vm.prank(owner);
        IOwnable(address(loan)).acceptOwnership();

        // allow this test contract to mint USDC
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(voter), 100e6);
        usdc.mint(address(vault), 100e6);
        vm.stopPrank();

        vm.prank(address(user));
        voter.reset(tokenId);
        vm.stopPrank();
        vm.prank(votingEscrow.ownerOf(3687));
        voter.reset(3687);
        vm.stopPrank();
        vm.prank(votingEscrow.ownerOf(3687));
        voter.reset(3687);
        vm.stopPrank();
    }

    function testOwner() public view {
        address o = loan.owner();
        assertEq(o, owner);
    }


    function testMaxLoan() public {
        (uint256 maxLoan,  ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 80e6);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        uint256 amount = 5e6;
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false, address(usdc));


        (maxLoan,  ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 75e6);

        loan.increaseLoan(tokenId, 70e6);
        (maxLoan,  ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 5e6);

        loan.increaseLoan(tokenId, 5e6);
        (maxLoan,  ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 0);
        vm.stopPrank();

    }



    
    function testGetMaxLoan() public {
        vm.startPrank(owner);
        loan.setMultiplier(8);
        loan.setRewardsRate(11300);
        vm.stopPrank();
        (uint256 maxLoan,  ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 204207);
    }

    function testNftOwner() public view {
        assertEq(votingEscrow.ownerOf(tokenId), address(user));
    }

    function testLoanRequest() public {
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        uint256 amount = 5e18;
        vm.expectRevert();
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false, address(usdc));

        amount = 1e6;
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false, address(usdc));
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > 1e6);
        assertTrue(usdc.balanceOf(address(vault)) < 100e6);

        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount);
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
    }


    function xtestLoanVotingAdvance() public {
        tokenId = 3687;
        user = votingEscrow.ownerOf(tokenId);

        uint256 amount = 1e6;
        
    
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false, address(usdc));
        vm.roll(block.number+1);
        vm.warp(block.timestamp + 3601);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > startingUserBalance, "User should have more than starting balance");
        assertEq(usdc.balanceOf(address(vault)), 99e6, "Vault should have 1e6");
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "Owner should have starting balance");


        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount, "Balance should be more than amount");
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
        assertEq(loan.activeAssets(), amount, "should have 0 active assets");

        address[] memory bribes = new address[](0);
        bytes memory data = hex"84a7f3dd020100015f3454Fa53E5866a4f69bBc2E6B9A041092D9Ad70703c19d0213c8780001b31f66aa3c1e785363f0875a1b74e27b85fd66c7077938fca12e5c4e00000001ffff003a6bad9b743d658048742935fffe2b6ed7080e9c7ed08b7ac7d500018B0D80F3EDd2631962BE8aE932c7B4558f8B23650001b97ef9ef8734c71904d8002f8b6bc66dd9c48a6e043b8f775b0001037eDa3aDB1198021A9b2e88C22B464fD38db3f3000000000401030500000202030200000102001e040b0101030401ff0000000000000000008b0d80f3edd2631962be8ae932c7b4558f8b2365ffff003a6bad9b743d658048742935fffe2b6ed7a20c959b19f114e9c2d81547734cdc1110bd773db31f66aa3c1e785363f0875a1b74e27b85fd66c700000000000000000000000000000000";
        uint256[2] memory allocations = [uint256(expectedRewards), uint256(0)];
        uint256 rewards = _claimRewards(loan, tokenId, bribes, data, allocations);
        assertEq(rewards, expectedRewards, "rewards should be expectedRewards");
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 172913);
    }

    function xtestIncreaseAmountPercentage20() public {
        tokenId = 3687;
        user = votingEscrow.ownerOf(tokenId);

        uint256 amount = 1e6;
        
    
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false, address(usdc));
        vm.roll(block.number+1);
        vm.warp(block.timestamp + 3601);
        loan.setIncreasePercentage(tokenId, 2000);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > startingUserBalance, "User should have more than starting balance");
        assertEq(usdc.balanceOf(address(vault)), 99e6, "Vault should have 1e6");
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "Owner should have starting balance");


        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount, "Balance should be more than amount");
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
        assertEq(loan.activeAssets(), amount, "should have 0 active assets");

        address[] memory bribes = new address[](0);
        bytes memory data = hex"84a7f3dd020100015f3454Fa53E5866a4f69bBc2E6B9A041092D9Ad70703c19d0213c8780001b31f66aa3c1e785363f0875a1b74e27b85fd66c7077938fca12e5c4e00000001ffff003a6bad9b743d658048742935fffe2b6ed7080e9c7ed08b7ac7d500018B0D80F3EDd2631962BE8aE932c7B4558f8B23650001b97ef9ef8734c71904d8002f8b6bc66dd9c48a6e043b8f775b0001037eDa3aDB1198021A9b2e88C22B464fD38db3f3000000000401030500000202030200000102001e040b0101030401ff0000000000000000008b0d80f3edd2631962be8ae932c7b4558f8b2365ffff003a6bad9b743d658048742935fffe2b6ed7a20c959b19f114e9c2d81547734cdc1110bd773db31f66aa3c1e785363f0875a1b74e27b85fd66c700000000000000000000000000000000";
        uint256[2] memory allocations = [uint256(expectedRewards), uint256(0)];
        uint256 rewards = _claimRewards(loan, tokenId, bribes, data, allocations);
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 172913);
    }

    function xtestIncreaseAmountPercentage50WithLoan() public {
        tokenId = 3687;
        user = votingEscrow.ownerOf(tokenId);

        uint256 amount = 1e6;
        
    
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false, address(usdc));
        vm.roll(block.number+1);
        vm.warp(block.timestamp + 3601);
        loan.setIncreasePercentage(tokenId, 5000);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > startingUserBalance, "User should have more than starting balance");
        assertEq(usdc.balanceOf(address(vault)), 99e6, "Vault should have 1e6");
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "Owner should have starting balance");


        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount, "Balance should be more than amount");
        assertEq(borrower, user);

        uint256 nftBalance = votingEscrow.balanceOfNFTAt(tokenId, block.timestamp);
        console.log(nftBalance);
        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
        assertEq(loan.activeAssets(), amount, "should have 0 active assets");

        address[] memory bribes = new address[](0);
        bytes memory data = hex"84a7f3dd020200015f3454Fa53E5866a4f69bBc2E6B9A041092D9Ad70ada278e2a9c28900000000001b31f66aa3c1e785363f0875a1b74e27b85fd66c7077938fca12e5c4e00000001ffff003a6bad9b743d658048742935fffe2b6ed7080e9c7ed08b7ac7d500019962Cf3ba621bEb96D3fA2614D24161A717ada710001b97ef9ef8734c71904d8002f8b6bc66dd9c48a6e080de1420c44a46e800001037eDa3aDB1198021A9b2e88C22B464fD38db3f30001aaab9d12a30504559b0c5a9a5977fee4a6081c6b041fec6c6c0001037eDa3aDB1198021A9b2e88C22B464fD38db3f300000000060204060195a33bf60002000b0301010200020302000003040001040b0101050201ff000000000000000000000000000000000000000000000000000000000000b0336b14d76d373b9ec711efef67a5922e0cad62b31f66aa3c1e785363f0875a1b74e27b85fd66c79962cf3ba621beb96d3fa2614d24161a717ada71ffff003a6bad9b743d658048742935fffe2b6ed7a20c959b19f114e9c2d81547734cdc1110bd773d00000000000000000000000000000000000000000000000000000000";
        uint256[2] memory allocations = [uint256(1027835), uint256(482898852822771)];
        uint256 rewards = _claimRewards(loan, tokenId, bribes, data, allocations);
        nftBalance = votingEscrow.balanceOfNFTAt(tokenId, block.timestamp);
        assertTrue(nftBalance >= 994807632341109944);
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 172913);
    }


    function xtestIncreaseAmountPercentage100WithLoan() public {
        tokenId = 3687;
        user = votingEscrow.ownerOf(tokenId);

        uint256 amount = 1e6;
        
    
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false, address(usdc));
        vm.roll(block.number+1);
        vm.warp(block.timestamp + 3601);
        loan.setIncreasePercentage(tokenId, 10000);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > startingUserBalance, "User should have more than starting balance");
        assertEq(usdc.balanceOf(address(vault)), 99e6, "Vault should have 1e6");
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "Owner should have starting balance");


        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount, "Balance should be more than amount");
        assertEq(borrower, user);

        uint256 nftBalance = votingEscrow.balanceOfNFTAt(tokenId, block.timestamp);
        console.log(nftBalance);
        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
        assertEq(loan.activeAssets(), amount, "should have 0 active assets");

        address[] memory bribes = new address[](0);
        bytes memory data = hex"84a7f3dd020100015f3454Fa53E5866a4f69bBc2E6B9A041092D9Ad70ad9daf43fcef0400000000001b31f66aa3c1e785363f0875a1b74e27b85fd66c7077938fca12e5c4e00000001ffff003a6bad9b743d658048742935fffe2b6ed7080e9c7ed08b7ac7d500019962Cf3ba621bEb96D3fA2614D24161A717ada710001aaab9d12a30504559b0c5a9a5977fee4a6081c6b042237923a0001037eDa3aDB1198021A9b2e88C22B464fD38db3f30000000004010305000002020302000001020001040301010103040064ff000000000000009962cf3ba621beb96d3fa2614d24161a717ada71ffff003a6bad9b743d658048742935fffe2b6ed7aaa3f202babcf7d6493afbc0caee03af9c64f984b31f66aa3c1e785363f0875a1b74e27b85fd66c700000000000000000000000000000000";
        uint256[2] memory allocations = [uint256(expectedRewards), uint256(0)];
        uint256 rewards = _claimRewards(loan, tokenId, bribes, data, allocations);
        nftBalance = votingEscrow.balanceOfNFTAt(tokenId, block.timestamp);
        assertTrue(nftBalance >= 994807632341109944);
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 172913);
    }

    function xtestIncreaseAmountPercentage100NoLoan() public {
        tokenId = 3687;
        user = votingEscrow.ownerOf(tokenId);

        uint256 amount = 0;
        
    
        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertEq(rewardsPerEpoch, 0, "rewardsPerEpoch should be  0");

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.InvestToVault, 0, address(0), false, false, address(usdc));
        vm.roll(block.number+1);
        loan.setIncreasePercentage(tokenId, 10000);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "Owner should have starting balance");


        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertEq(balance,  0, "Balance should be 0");
        assertEq(borrower, user);

        uint256 nftBalance = votingEscrow.balanceOfNFTAt(tokenId, block.timestamp);
        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
        assertEq(loan.activeAssets(), amount, "should have 0 active assets");

        address[] memory bribes = new address[](0);
        bytes memory data = hex"84a7f3dd020100015f3454Fa53E5866a4f69bBc2E6B9A041092D9Ad70ad9daf43fcef0400000000001b31f66aa3c1e785363f0875a1b74e27b85fd66c7077938fca12e5c4e00000001ffff003a6bad9b743d658048742935fffe2b6ed7080e9c7ed08b7ac7d500019962Cf3ba621bEb96D3fA2614D24161A717ada710001aaab9d12a30504559b0c5a9a5977fee4a6081c6b042237923a0001037eDa3aDB1198021A9b2e88C22B464fD38db3f30000000004010305000002020302000001020001040301010103040064ff000000000000009962cf3ba621beb96d3fa2614d24161a717ada71ffff003a6bad9b743d658048742935fffe2b6ed7aaa3f202babcf7d6493afbc0caee03af9c64f984b31f66aa3c1e785363f0875a1b74e27b85fd66c700000000000000000000000000000000";
        uint256[2] memory allocations = [uint256(expectedRewards), uint256(36117747185770)];
        uint256 rewardsClaimed = _claimRewards(loan, tokenId, bribes, data, allocations);
        console.log("LOAN BALANCE", usdc.balanceOf(address(loan)));
        console.log("Reards claimed", rewardsClaimed);
        console.log("owner", address(owner));
        assertEq(rewardsClaimed, expectedRewards);
        nftBalance = votingEscrow.balanceOfNFTAt(tokenId, block.timestamp);
        assertTrue(nftBalance >= 997150273160109328);
        assertEq(aero.balanceOf(address(owner)), 361177471857, "owner should have gained");
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should not have gained");
        assertEq(loan.activeAssets(), 0, "should not have active assets");


        rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertEq(rewardsPerEpoch, 0, "rewardsPerEpoch should be  0");

        assertEq(vault.epochRewardsLocked(), 0);
    }

    function xtestIncreaseAmountPercentage75NoLoan() public {
        tokenId = 3687;
        user = votingEscrow.ownerOf(tokenId);

        uint256 amount = 0;
        
    
        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertEq(rewardsPerEpoch, 0, "rewardsPerEpoch should be  00f");

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.InvestToVault, 0, address(0), false, false, address(usdc));
        vm.roll(block.number+1);
        vm.warp(block.timestamp + 3601);
        loan.setIncreasePercentage(tokenId, 7500);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "Owner should have starting balance");


        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertEq(balance,  0, "Balance should be 0");
        assertEq(borrower, user);

        uint256 nftBalance = votingEscrow.balanceOfNFTAt(tokenId, block.timestamp);
        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
        assertEq(loan.activeAssets(), amount, "should have 0 active assets");

        address[] memory bribes = new address[](0);
        bytes memory data = hex"84a7f3dd020200015f3454Fa53E5866a4f69bBc2E6B9A041092D9Ad70ad935b2e457a4f80000000001b31f66aa3c1e785363f0875a1b74e27b85fd66c7077938fca12e5c4e00000001ffff003a6bad9b743d658048742935fffe2b6ed7080e9c7ed08b7ac7d500019962Cf3ba621bEb96D3fA2614D24161A717ada710001b97ef9ef8734c71904d8002f8b6bc66dd9c48a6e080de3a24c639828000001037eDa3aDB1198021A9b2e88C22B464fD38db3f30001aaab9d12a30504559b0c5a9a5977fee4a6081c6b041f40eba90001037eDa3aDB1198021A9b2e88C22B464fD38db3f3000000000802040a019539cc7e0002000b0300010200020302000003040001040001060002020b0306060201040b01010708010607020100050900ff00000000000000000066a5de11d1e1f20da825d974453f099c4bb13647b31f66aa3c1e785363f0875a1b74e27b85fd66c79962cf3ba621beb96d3fa2614d24161a717ada71ffff003a6bad9b743d658048742935fffe2b6ed713e09b6a2919413f8436ecb3b963a47a6fe5c616d011625b43727e7e9dc684c15ca30a70cdbef7a8770f5f599301b61d7101637d9784ae6156726c1849d5c2bdffac6ce2bfdb6640f4f80f226bc10babd5d0a9b3f2c264b955ae7161cfa6d38a7aea60a7000000000000000000000000";
        uint256[2] memory allocations = [uint256(1020654), uint256(2670931523329828)];
        uint256 rewardsClaimed = _claimRewards(loan, tokenId, bribes, data, allocations);
        assertEq(rewardsClaimed, 1020654);
        nftBalance = votingEscrow.balanceOfNFTAt(tokenId, block.timestamp);
        assertTrue(nftBalance >= 996367037369959857);
        assertEq(usdc.balanceOf(address(owner)), 3345, "owner should have gained");
        assertEq(aero.balanceOf(address(owner)), 26709315233298, "owner should have gained");
        assertEq(loan.activeAssets(), 0, "should not have active assets");

        rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertEq(rewardsPerEpoch, 0, "rewardsPerEpoch should be  0");

        assertEq(vault.epochRewardsLocked(), 0);
    }

    // function xxtestIncreaseAmountPercentage75NoLoanToCommunityToken2() public {
    //     user = votingEscrow.ownerOf(tokenId);

    //     address[] memory tokens = new address[](1);
    //     tokens[0] = address(usdc);
            
    //     address[] memory bribes = new address[](0);

    //     address veOwner = votingEscrow.ownerOf(3687);
    //     vm.startPrank(veOwner);
    //     CommunityRewards _communityRewards = new CommunityRewards();
    //     ERC1967Proxy _proxy = new ERC1967Proxy(address(_communityRewards), "");
    //     vm.roll(block.number + 1);
    //     votingEscrow.approve(address(_proxy), 3687);
    //     CommunityRewards(address(_proxy)).initialize(address(loan), tokens, 0, 3687, 0xAAAEa1fB9f3DE3F70E89f37B69Ab11B47eb9Ce6F);
    //     vm.stopPrank();
    //     vm.startPrank(owner);
    //     loan.setManagedNft(3687);

    //     uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
    //     assertEq(rewardsPerEpoch, 0, "rewardsPerEpoch should be  0");

    //     uint256 startingUserBalance = usdc.balanceOf(address(user));

    //     assertEq(usdc.balanceOf(address(user)), startingUserBalance);
    //     assertEq(usdc.balanceOf(address(vault)), 100e6);
    //     assertEq(loan.activeAssets(),0, "should have 0 active assets");
    //     vm.startPrank(user);
    //     IERC721(address(votingEscrow)).approve(address(loan), tokenId);
    //     loan.requestLoan(tokenId, 0, Loanv2.ZeroBalanceOption.InvestToVault, 0, address(0), false, false, address(usdc));
    //     vm.roll(block.number+1);
    //     vm.warp(block.timestamp + 3601);
    //     loan.setIncreasePercentage(tokenId, 10000);
    //     uint256[] memory tokenIds = new uint256[](1);
    //     tokenIds[0] = tokenId;
    //     loan.setOptInCommunityRewards(tokenIds, true);
    //     vm.stopPrank();


    //     CommunityRewards communityRewards = CommunityRewards(address(_proxy));
    //     vm.startPrank(address(loan));
    //     bytes memory data = hex"84a7f3dd020100015f3454Fa53E5866a4f69bBc2E6B9A041092D9Ad70703c19d0213c8780001b31f66aa3c1e785363f0875a1b74e27b85fd66c7077938fca12e5c4e00000001ffff003a6bad9b743d658048742935fffe2b6ed7080e9c7ed08b7ac7d500018B0D80F3EDd2631962BE8aE932c7B4558f8B23650001b97ef9ef8734c71904d8002f8b6bc66dd9c48a6e043b8f775b0001037eDa3aDB1198021A9b2e88C22B464fD38db3f3000000000401030500000202030200000102001e040b0101030401ff0000000000000000008b0d80f3edd2631962be8ae932c7b4558f8b2365ffff003a6bad9b743d658048742935fffe2b6ed7a20c959b19f114e9c2d81547734cdc1110bd773db31f66aa3c1e785363f0875a1b74e27b85fd66c700000000000000000000000000000000";
    //     uint256[2] memory allocations = [uint256(expectedRewards), uint256(0)];
    //     uint256 rewards = _claimRewards(loan, 3687, bribes, data, allocations);
    //     vm.stopPrank();


    //     vm.roll(block.number + 1);
    //     vm.warp(block.timestamp + 7 days);
    //     IMinter(0xAAA823aa799BDa3193D46476539bcb1da5B71330).updatePeriod();
    //     uint256 ownerShares = communityRewards.balanceOf(owner);
    //     rewards = _claimRewards(loan, 3687, bribes, data, allocations);
    //     uint256 userBalance = usdc.balanceOf(address(user));
    //     assertTrue(ownerShares > 0, "owner should have shares");
        
    //     uint256 ownerUsdBalance = usdc.balanceOf(address(owner));
    //     vm.roll(block.number + 1);
    //     vm.warp(block.timestamp + 7 days);
    //     vm.prank(address(loan));
    //     communityRewards.notifyRewardAmount(tokens[0], 10e6);
    //     usdc.mint(address(communityRewards), 10e6);
    //     communityRewards.getRewardForUser(user, tokens);
    //     communityRewards.getRewardForUser(owner, tokens);

    //     assertTrue(usdc.balanceOf(address(owner)) > ownerUsdBalance, "owner should have more than starting balance");
    // }

    function testIncreaseLoan() public {
        uint256 amount = 1e6;

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "ff");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false, address(usdc));
        vm.roll(block.number+1);
        vm.warp(block.timestamp + 3601);
        vm.warp(block.timestamp+1);
        loan.vote(tokenId);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > 1e6, "User should have more than loan");

        assertEq(loan.activeAssets(),1e6, "ff");
        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount, "Balance should be 1e6");
        assertEq(borrower, user);

        vm.startPrank(user);
        loan.increaseLoan(tokenId, amount);
        vm.stopPrank();

        (balance, borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance> amount, "Balance should be more than amount");
        assertEq(borrower, user);
        assertEq(loan.activeAssets(),2e6, "ff");

        assertEq(usdc.balanceOf(address(user)), 2e6 + startingUserBalance, "User should have .02e6");
        assertEq(usdc.balanceOf(address(vault)), 98e6, "Loan should have 1e6");
        
    }

    function testLoanFullPayoff() public {
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(user), 100e6);
        vm.stopPrank();

        uint256 amount = 1e6;

        assertEq(votingEscrow.ownerOf(tokenId), address(user), "User should own token");

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance, "User should have startingUserBalance");
        assertEq(usdc.balanceOf(address(vault)), 100e6);

        address[] memory manualPools = new address[](1);
        manualPools[0] = address(0xa20c959b19F114e9C2D81547734CdC1110bd773D);

        vm.startPrank(Ownable2StepUpgradeable(loan).owner());
        loan.setApprovedPools(manualPools, true);
        vm.stopPrank();
        vm.startPrank(user);
        
        uint256[] memory manualWeights = new uint256[](1);
        manualWeights[0] = 100e18;
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false, address(usdc));
        vm.roll(block.number+1);
        vm.warp(block.timestamp + 1);
        loan.userVote(tokenIds, manualPools, manualWeights);

        vm.stopPrank();
        assertEq(usdc.balanceOf(address(user)), 1e6+startingUserBalance, "User should have 1e6");
        assertEq(usdc.balanceOf(address(vault)), 99e6, "Loan should have 97e6");

        assertEq(votingEscrow.ownerOf(tokenId), address(loan));

        vm.startPrank(user);
        usdc.approve(address(loan), 5e6);
        vm.expectRevert();
        loan.reset(tokenId); // should not be able to reset loan with balance
        loan.pay(tokenId, 0);
        loan.reset(tokenId);
        loan.claimCollateral(tokenId);
        vm.stopPrank();

        assertEq(votingEscrow.ownerOf(tokenId), address(user));
    }


    function testUpgradeLoan() public {
        vm.startPrank(loan.owner());
        Loan loanV2 = new Loan();
        loan.upgradeToAndCall(address(loanV2), new bytes(0));
        vm.stopPrank();
    }


    function xtestReinvestVault() public {
        assertEq(usdc.balanceOf(address(vault)), 100e6, "vault should have 0 balance");
        uint256 _tokenId = 3687;

        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));
        uint256 startingVaultBalance = usdc.balanceOf(address(vault));
        
        user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, 0, Loanv2.ZeroBalanceOption.InvestToVault, 0, address(0), false, false, address(usdc));
        vm.roll(block.number+1);
        vm.warp(block.timestamp + 3601);
        vm.stopPrank();
        
        address[] memory bribes = new address[](0);
        bytes memory data = hex"84a7f3dd020100015f3454Fa53E5866a4f69bBc2E6B9A041092D9Ad70703c19d0213c8780001b31f66aa3c1e785363f0875a1b74e27b85fd66c7077938fca12e5c4e00000001ffff003a6bad9b743d658048742935fffe2b6ed7080e9c7ed08b7ac7d500018B0D80F3EDd2631962BE8aE932c7B4558f8B23650001b97ef9ef8734c71904d8002f8b6bc66dd9c48a6e043b8f775b0001037eDa3aDB1198021A9b2e88C22B464fD38db3f3000000000401030500000202030200000102001e040b0101030401ff0000000000000000008b0d80f3edd2631962be8ae932c7b4558f8b2365ffff003a6bad9b743d658048742935fffe2b6ed7a20c959b19f114e9c2d81547734cdc1110bd773db31f66aa3c1e785363f0875a1b74e27b85fd66c700000000000000000000000000000000";
        uint256[2] memory allocations = [uint256(expectedRewards), uint256(0)];
        _claimRewards(loan, tokenId, bribes, data, allocations);

        uint256 endingOwnerBalance = usdc.balanceOf(address(owner));

        

        // owner should not receive rewards
        assertNotEq(endingOwnerBalance - startingOwnerBalance, 0, "owner should receive rewards");
        assertTrue(usdc.balanceOf(address(vault)) > startingVaultBalance, "vault should have more than starting balance");
    }


    function xtestPayToOwner() public {
        assertEq(usdc.balanceOf(address(vault)), 100e6, "vault should have 0 balance");
        uint256 _tokenId = 3687;
        console.log("LOAN:L", address(loan));
        
        uint256 loanBeginningBalance = usdc.balanceOf(address(loan));
        user = votingEscrow.ownerOf(_tokenId);
        uint256 startingOwnerBalance = usdc.balanceOf(address(Ownable2StepUpgradeable(loan).owner()));
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingLoanBalance = usdc.balanceOf(address(loan));
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, 0, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false, address(usdc));
        vm.roll(block.number+1);
        vm.warp(block.timestamp + 3601);
        vm.stopPrank();
        

        address[] memory bribes = new address[](0);
        bytes memory data = hex"84a7f3dd020100015f3454Fa53E5866a4f69bBc2E6B9A041092D9Ad70703c19d0213c8780001b31f66aa3c1e785363f0875a1b74e27b85fd66c7077938fca12e5c4e00000001ffff003a6bad9b743d658048742935fffe2b6ed7080e9c7ed08b7ac7d500018B0D80F3EDd2631962BE8aE932c7B4558f8B23650001b97ef9ef8734c71904d8002f8b6bc66dd9c48a6e043b8f775b0001037eDa3aDB1198021A9b2e88C22B464fD38db3f3000000000401030500000202030200000102001e040b0101030401ff0000000000000000008b0d80f3edd2631962be8ae932c7b4558f8b2365ffff003a6bad9b743d658048742935fffe2b6ed7a20c959b19f114e9c2d81547734cdc1110bd773db31f66aa3c1e785363f0875a1b74e27b85fd66c700000000000000000000000000000000";
        uint256[2] memory allocations = [uint256(expectedRewards), uint256(0)];
        uint256 rewards = _claimRewards(loan, tokenId, bribes, data, allocations);

        uint256 endingUserBalance = usdc.balanceOf(address(user));
        uint256 endingOwnerBalance = usdc.balanceOf(address(Ownable2StepUpgradeable(loan).owner()));
        uint256 endingLoanBalance = usdc.balanceOf(address(loan));

        uint256 totalRewards = endingUserBalance - startingUserBalance + endingOwnerBalance - startingOwnerBalance;


        // owner should receive rewards 1% f rewards
        uint256 protocolFee = totalRewards / 100;
        uint256 paidToUser = totalRewards - protocolFee;        
        assertTrue(paidToUser > 0, "user should receive rewards");
        assertTrue(protocolFee > 0, "owner should receive rewards");
        assertEq(endingUserBalance - startingUserBalance, paidToUser,  "user should receive rewards");
        assertEq(endingOwnerBalance - startingOwnerBalance, protocolFee, "owner should receive rewards");
        assertEq(endingLoanBalance - startingLoanBalance, 0, "loan should not receive rewards");        
        uint256 loanEndingBalance = usdc.balanceOf(address(loan));
        assertEq(loanEndingBalance - loanBeginningBalance, 0, "loan should not have balance");
    }

    function xtestPayToOwnerPayoutToken() public {
        assertEq(usdc.balanceOf(address(vault)), 100e6, "vault should have 0 balance");
        uint256 _tokenId = 3687;

        
        address _owner = Ownable2StepUpgradeable(loan).owner();
        vm.startPrank(_owner);
        loan.setApprovedToken(address(weth), true);
        vm.stopPrank();

        user = votingEscrow.ownerOf(_tokenId);
        uint256 startingOwnerBalance = weth.balanceOf(address(Ownable2StepUpgradeable(loan).owner()));
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingLoanBalance = usdc.balanceOf(address(loan));
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, 0, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false, address(usdc));
        vm.roll(block.number+1);
        vm.warp(block.timestamp + 3601);
        vm.warp(block.timestamp+1);
        loan.setPreferredToken(_tokenId, address(weth));
        vm.stopPrank();
        

        address[] memory bribes = new address[](0);
        bytes memory data = hex"84a7f3dd020100015f3454Fa53E5866a4f69bBc2E6B9A041092D9Ad70703c19d0213c8780001b31f66aa3c1e785363f0875a1b74e27b85fd66c7077938fca12e5c4e00000001ffff003a6bad9b743d658048742935fffe2b6ed7080e9c7ed08b7ac7d500018B0D80F3EDd2631962BE8aE932c7B4558f8B23650001b97ef9ef8734c71904d8002f8b6bc66dd9c48a6e043b8f775b0001037eDa3aDB1198021A9b2e88C22B464fD38db3f3000000000401030500000202030200000102001e040b0101030401ff0000000000000000008b0d80f3edd2631962be8ae932c7b4558f8b2365ffff003a6bad9b743d658048742935fffe2b6ed7a20c959b19f114e9c2d81547734cdc1110bd773db31f66aa3c1e785363f0875a1b74e27b85fd66c700000000000000000000000000000000";
        uint256[2] memory allocations = [uint256(expectedRewards), uint256(0)];
        uint256 rewards = _claimRewards(loan, tokenId, bribes, data, allocations);

        uint256 endingUserBalance = weth.balanceOf(address(user));
        uint256 endingOwnerBalance = usdc.balanceOf(address(Ownable2StepUpgradeable(loan).owner()));
        uint256 endingLoanBalance = usdc.balanceOf(address(loan));



        // owner should receive rewards in usdc 
        assertNotEq(endingOwnerBalance - startingOwnerBalance, 0, "owner should receive usd rewards");

        assertNotEq(endingUserBalance - startingUserBalance, 0,  "user should have receive weth rewards");

        assertEq(endingLoanBalance - startingLoanBalance, 0, "loan should not receive rewards");        
    }

    // function testManagedNft() public {
    //     uint256 _tokenId = 3687;
    //     address _user = votingEscrow.ownerOf(_tokenId);
    //     vm.prank(_user);
    //     votingEscrow.transferFrom(_user, address(this), _tokenId);

    //     address[] memory tokens = new address[](1);
    //     tokens[0] = address(usdc);
        
    //     CommunityRewards _communityRewards = new CommunityRewards();
    //     ERC1967Proxy _proxy = new ERC1967Proxy(address(_communityRewards), "");
    //     votingEscrow.approve(address(_proxy), _tokenId);
    //     vm.roll(block.number + 1);
    //     CommunityRewards(address(_proxy)).initialize(address(loan), tokens, 2500e18, _tokenId, 0xAAAEa1fB9f3DE3F70E89f37B69Ab11B47eb9Ce6F);

        

    //     vm.prank(0xeefbd314141BF7933Be47E44C1dC1437e58604Cb);
    //     aero.transfer(_user, 10e18);
    //     vm.startPrank(_user);
    //     aero.approve(address(votingEscrow), 10e18);
    //     uint256 newLockId = votingEscrow.createLock(10e18, 604800);
    //     vm.stopPrank();

    //     vm.roll(block.number + 1);
    //     vm.warp(block.timestamp + 1);
        
    //     address _user2 = votingEscrow.ownerOf(newLockId);
    //     console.log("new lock id: %s", newLockId);
    //     vm.roll(block.number + 1);
    //     vm.warp(block.timestamp + 1);
    //     uint256 nftBalance = votingEscrow.balanceOfNFT(newLockId);
    //     assertTrue(nftBalance > 0, "should not have balance");
    //     vm.prank(_user2);
    //     votingEscrow.transferFrom(_user2, address(loan), newLockId);

    //     vm.roll(block.number + 1);
    //     vm.warp(block.timestamp + 1);
    //     address _owner = Ownable2StepUpgradeable(loan).owner();
    //     vm.prank(_owner);
    //     loan.setManagedNft(3687);

    //     vm.roll(block.number + 1);
    //     vm.warp(block.timestamp + 1);
    //     uint256 beginningBalance = votingEscrow.balanceOfNFT(_tokenId);
    //     vm.startPrank(_owner);
    //     loan.mergeIntoManagedNft(newLockId);
    //     assertTrue(votingEscrow.balanceOfNFT(_tokenId) > beginningBalance, "should have more balance");

    //     vm.roll(block.number + 1);
    //     vm.warp(block.timestamp + 1);
    //     assertEq(votingEscrow.ownerOf(newLockId), address(0), "should be burnt");
    //     vm.expectRevert();
    //     loan.setManagedNft(newLockId);

    //     address[] memory bribes = new address[](0);
    //     CommunityRewards communityRewards = CommunityRewards(address(_proxy));
    //     address user1 = address(0x353641);
    //     address user2 = address(0x26546);
    //     vm.startPrank(address(loan));
    //     communityRewards.deposit(uint256(3687), 10e18, user1);
    //     communityRewards.deposit(uint256(3687), 10e18, user2);
    //     vm.stopPrank();


    //     vm.roll(block.number + 1);
    //     vm.warp(block.timestamp + 7 days);


    //     IMinter(0xAAA823aa799BDa3193D46476539bcb1da5B71330).updatePeriod();
    //     bytes memory data = hex"84a7f3dd020100015f3454Fa53E5866a4f69bBc2E6B9A041092D9Ad70703c19d0213c8780001b31f66aa3c1e785363f0875a1b74e27b85fd66c7077938fca12e5c4e00000001ffff003a6bad9b743d658048742935fffe2b6ed7080e9c7ed08b7ac7d500018B0D80F3EDd2631962BE8aE932c7B4558f8B23650001b97ef9ef8734c71904d8002f8b6bc66dd9c48a6e043b8f775b0001037eDa3aDB1198021A9b2e88C22B464fD38db3f3000000000401030500000202030200000102001e040b0101030401ff0000000000000000008b0d80f3edd2631962be8ae932c7b4558f8b2365ffff003a6bad9b743d658048742935fffe2b6ed7a20c959b19f114e9c2d81547734cdc1110bd773db31f66aa3c1e785363f0875a1b74e27b85fd66c700000000000000000000000000000000";
    //     uint256[2] memory allocations = [uint256(expectedRewards), uint256(0)];
    //      _claimRewards(loan, tokenId, bribes, data, allocations);
    //     uint256 rewards = communityRewards.tokenRewardsPerEpoch(address(usdc), ProtocolTimeLibrary.epochStart(block.timestamp) - ProtocolTimeLibrary.WEEK);
    //     assertTrue(rewards > 0, "rewards should be greater than 0");
    //     console.log(usdc.balanceOf(address(user1)));
    //     communityRewards.getRewardForUser(user1, tokens);
    //     communityRewards.getRewardForUser(user2, tokens);
    //     console.log(usdc.balanceOf(address(user1)));




    //     assertTrue(IERC20(address(usdc)).balanceOf(address(communityRewards)) <  10, "should be less than 10");

    //     // test setting increase percentage
    //     vm.expectRevert();
    //     communityRewards.setIncreasePercentage(0);
        
    //     vm.startPrank(_owner);
    //     communityRewards.setIncreasePercentage(0);
    // }

    // function testManagedNft2() public {
    //     uint256 _tokenId = 3687;
    //     address _user = votingEscrow.ownerOf(_tokenId);
    //     vm.prank(_user);
    //     votingEscrow.transferFrom(_user, address(this), _tokenId);

    //     address[] memory tokens = new address[](1);
    //     tokens[0] = address(usdc);
        
    //     CommunityRewards _communityRewards = new CommunityRewards();
    //     ERC1967Proxy _proxy = new ERC1967Proxy(address(_communityRewards), "");
    //     votingEscrow.approve(address(_proxy), _tokenId);
    //     vm.roll(block.number + 1);
    //     CommunityRewards(address(_proxy)).initialize(address(loan), tokens, 2500e18, _tokenId, 0xAAAEa1fB9f3DE3F70E89f37B69Ab11B47eb9Ce6F);

        

    //     vm.prank(0xeefbd314141BF7933Be47E44C1dC1437e58604Cb);
    //     aero.transfer(_user, 10e18);
    //     vm.startPrank(_user);
    //     aero.approve(address(votingEscrow), 10e18);
    //     uint256 newLockId = votingEscrow.createLock(10e18, 604800);
    //     vm.stopPrank();

    //     vm.roll(block.number + 1);
    //     vm.warp(block.timestamp + 1);
        
    //     address _user2 = votingEscrow.ownerOf(newLockId);
    //     console.log("new lock id: %s", newLockId);
    //     vm.roll(block.number + 1);
    //     vm.warp(block.timestamp + 1);
    //     uint256 nftBalance = votingEscrow.balanceOfNFT(newLockId);
    //     assertTrue(nftBalance > 0, "should not have balance");
    //     vm.prank(_user2);
    //     votingEscrow.transferFrom(_user2, address(loan), newLockId);

    //     vm.roll(block.number + 1);
    //     vm.warp(block.timestamp + 1);
    //     address _owner = Ownable2StepUpgradeable(loan).owner();
    //     vm.prank(_owner);
    //     loan.setManagedNft(3687);

    //     vm.roll(block.number + 1);
    //     vm.warp(block.timestamp + 1);
    //     uint256 beginningBalance = votingEscrow.balanceOfNFT(_tokenId);
    //     vm.startPrank(_owner);
    //     loan.mergeIntoManagedNft(newLockId);
    //     assertTrue(votingEscrow.balanceOfNFT(_tokenId) > beginningBalance, "should have more balance");

    //     vm.roll(block.number + 1);
    //     vm.warp(block.timestamp + 1);
    //     assertEq(votingEscrow.ownerOf(newLockId), address(0), "should be burnt");
    //     vm.expectRevert();
    //     loan.setManagedNft(newLockId);

    //     address[] memory bribes = new address[](0);
    //     CommunityRewards communityRewards = CommunityRewards(address(_proxy));
    //     address user1 = address(0x353641);
    //     address user2 = address(0x26546);
    //     vm.startPrank(address(loan));
    //     communityRewards.deposit(uint256(3687), 10e18, user1);
    //     communityRewards.deposit(uint256(3687), 10e18, user2);
    //     vm.stopPrank();


    //     vm.roll(block.number + 1);
    //     vm.warp(block.timestamp + 7 days);

    //     IMinter(0xAAA823aa799BDa3193D46476539bcb1da5B71330).updatePeriod();
    //     bytes memory data = hex"84a7f3dd020100015f3454Fa53E5866a4f69bBc2E6B9A041092D9Ad70703c19d0213c8780001b31f66aa3c1e785363f0875a1b74e27b85fd66c7077938fca12e5c4e00000001ffff003a6bad9b743d658048742935fffe2b6ed7080e9c7ed08b7ac7d500018B0D80F3EDd2631962BE8aE932c7B4558f8B23650001b97ef9ef8734c71904d8002f8b6bc66dd9c48a6e043b8f775b0001037eDa3aDB1198021A9b2e88C22B464fD38db3f3000000000401030500000202030200000102001e040b0101030401ff0000000000000000008b0d80f3edd2631962be8ae932c7b4558f8b2365ffff003a6bad9b743d658048742935fffe2b6ed7a20c959b19f114e9c2d81547734cdc1110bd773db31f66aa3c1e785363f0875a1b74e27b85fd66c700000000000000000000000000000000";
    //     uint256[2] memory allocations = [uint256(expectedRewards), uint256(0)];
    //     _claimRewards(loan, tokenId, bribes, data, allocations);
    //     uint256 rewards = communityRewards.tokenRewardsPerEpoch(address(usdc), ProtocolTimeLibrary.epochStart(block.timestamp) - ProtocolTimeLibrary.WEEK);
    //     assertTrue(rewards > 0, "rewards should be greater than 0");
       
    //     communityRewards.getRewardForUser(user1, tokens);
    //     communityRewards.getRewardForUser(user2, tokens);

    //     assertTrue(IERC20(address(usdc)).balanceOf(address(communityRewards)) <  10, "should be less than 10");

    //     // test setting increase percentage
    //     vm.expectRevert();
    //     communityRewards.setIncreasePercentage(0);
        
    //     vm.startPrank(_owner);
    //     communityRewards.setIncreasePercentage(0);
    // }


    function testMerge() public {
        uint256 _tokenId = 3687;
        address _user = votingEscrow.ownerOf(tokenId);
        vm.startPrank(_user);        
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 0, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), true, false, address(usdc));
        vm.stopPrank();
        
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        
        address _user2 = votingEscrow.ownerOf(_tokenId);
        vm.prank(_user2);
        votingEscrow.transferFrom(_user2, address(_user), _tokenId);

      
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        vm.startPrank(_user);

        voter.reset(_tokenId);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        

        require(votingEscrow.isApprovedOrOwner(address(loan), _tokenId), "should be approved");
        require(votingEscrow.isApprovedOrOwner(address(loan), tokenId), "should be approved");
        require(votingEscrow.isApprovedOrOwner(address(_user), _tokenId), "should be approved");


        loan.merge(_tokenId, tokenId);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        assertEq(votingEscrow.ownerOf(_tokenId), address(0), "should be burnt");
    }

    function xtestPayoffToken() public {
        usdc.mint(address(vault), 100000e6);

        uint256 _tokenId = 3687;
        uint256 _tokenId2 = tokenId;

        uint256 loanAmount = .1e6;

        user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, loanAmount, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false, address(usdc));

        vm.stopPrank();

        address user2 = votingEscrow.ownerOf(_tokenId2);
        vm.stopPrank();
        vm.prank(user2);
        votingEscrow.transferFrom(user2, user, _tokenId2);
        
        vm.startPrank(user);
        vm.warp(block.timestamp+1);
        vm.roll(block.number + 1);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId2);
        loan.requestLoan(_tokenId2, loanAmount, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false, address(usdc));
        loan.setPayoffToken(_tokenId2, true);


        address[] memory bribes = new address[](0);
        bytes memory data = hex"84a7f3dd020100015f3454Fa53E5866a4f69bBc2E6B9A041092D9Ad70703c19d0213c8780001b31f66aa3c1e785363f0875a1b74e27b85fd66c7077938fca12e5c4e00000001ffff003a6bad9b743d658048742935fffe2b6ed7080e9c7ed08b7ac7d500018B0D80F3EDd2631962BE8aE932c7B4558f8B23650001b97ef9ef8734c71904d8002f8b6bc66dd9c48a6e043b8f775b0001037eDa3aDB1198021A9b2e88C22B464fD38db3f3000000000401030500000202030200000102001e040b0101030401ff0000000000000000008b0d80f3edd2631962be8ae932c7b4558f8b2365ffff003a6bad9b743d658048742935fffe2b6ed7a20c959b19f114e9c2d81547734cdc1110bd773db31f66aa3c1e785363f0875a1b74e27b85fd66c700000000000000000000000000000000";
        uint256[2] memory allocations = [uint256(expectedRewards), uint256(0)];
        _claimRewards(loan, tokenId, bribes, data, allocations);


        (uint256 balance,) = loan.getLoanDetails(_tokenId2);
        console.log("balance: %s", balance);
        console.log("loanAmount: %s", loanAmount);
        assertTrue(balance < loanAmount, "Balance should be less than amount");
        (balance,) = loan.getLoanDetails(_tokenId);
        assertEq(balance, 0, "Balance should be 0");
    }

    function xtestPayoffTokenMoreBalance() public {

        usdc.mint(address(vault), 100000e6);

        uint256 _tokenId = tokenId;
        uint256 _tokenId2 = 3687;


        uint256 loanAmount = 2e6;

        user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, loanAmount, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false, address(usdc));

        vm.stopPrank();

        address user2 = votingEscrow.ownerOf(_tokenId2);
        vm.stopPrank();
        vm.prank(user2);
        votingEscrow.transferFrom(user2, user, _tokenId2);
        
        vm.startPrank(user);
        vm.warp(block.timestamp+1);
        vm.roll(block.number + 1);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId2);
        loan.requestLoan(_tokenId2, loanAmount, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false, address(usdc));
        loan.setPayoffToken(_tokenId2, true);


        address[] memory bribes = new address[](0);
        bytes memory data = hex"84a7f3dd020100015f3454Fa53E5866a4f69bBc2E6B9A041092D9Ad70703c19d0213c8780001b31f66aa3c1e785363f0875a1b74e27b85fd66c7077938fca12e5c4e00000001ffff003a6bad9b743d658048742935fffe2b6ed7080e9c7ed08b7ac7d500018B0D80F3EDd2631962BE8aE932c7B4558f8B23650001b97ef9ef8734c71904d8002f8b6bc66dd9c48a6e043b8f775b0001037eDa3aDB1198021A9b2e88C22B464fD38db3f3000000000401030500000202030200000102001e040b0101030401ff0000000000000000008b0d80f3edd2631962be8ae932c7b4558f8b2365ffff003a6bad9b743d658048742935fffe2b6ed7a20c959b19f114e9c2d81547734cdc1110bd773db31f66aa3c1e785363f0875a1b74e27b85fd66c700000000000000000000000000000000";
        uint256[2] memory allocations = [uint256(expectedRewards), uint256(0)];
        _claimRewards(loan, tokenId, bribes, data, allocations);


        (uint256 balance,) = loan.getLoanDetails(_tokenId2);
        console.log("balance: %s", balance);
        assertTrue(balance < loanAmount, "Balance should be less than amount");
        (balance,) = loan.getLoanDetails(_tokenId);
        assertNotEq(balance, 0, "Balance should not be 0");
    }

    function xtestIncreaseAmountPercentage52() public {
        tokenId = 3687;
        user = votingEscrow.ownerOf(tokenId);

        uint256 amount = 1e6;
        
    
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false, address(usdc));
        vm.roll(block.number+1);
        vm.warp(block.timestamp + 3601);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > startingUserBalance, "User should have more than starting balance");
        assertEq(usdc.balanceOf(address(vault)), 99e6, "Vault should have 1e6");
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "Owner should have starting balance");


        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount, "Balance should be more than amount");
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
        assertEq(loan.activeAssets(), amount, "should have 0 active assets");

        address[] memory bribes = new address[](0);
        bytes memory data = hex"84a7f3dd020100015f3454Fa53E5866a4f69bBc2E6B9A041092D9Ad70703c19d0213c8780001b31f66aa3c1e785363f0875a1b74e27b85fd66c7077938fca12e5c4e00000001ffff003a6bad9b743d658048742935fffe2b6ed7080e9c7ed08b7ac7d500018B0D80F3EDd2631962BE8aE932c7B4558f8B23650001b97ef9ef8734c71904d8002f8b6bc66dd9c48a6e043b8f775b0001037eDa3aDB1198021A9b2e88C22B464fD38db3f3000000000401030500000202030200000102001e040b0101030401ff0000000000000000008b0d80f3edd2631962be8ae932c7b4558f8b2365ffff003a6bad9b743d658048742935fffe2b6ed7a20c959b19f114e9c2d81547734cdc1110bd773db31f66aa3c1e785363f0875a1b74e27b85fd66c700000000000000000000000000000000";
        uint256[2] memory allocations = [uint256(expectedRewards), uint256(0)];
        uint256 rewards = _claimRewards(loan, tokenId, bribes, data, allocations);
        assertEq(rewards, 1261867, "rewards should be 957174473");
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 172913);
    }

    function xtestTopup() public {
        usdc.mint(address(vault), 100000e6);

        uint256 _tokenId = 3687;

        uint256 loanAmount = .1e6;

        user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, loanAmount, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false, address(usdc));

        vm.stopPrank();

        uint256 _tokenId2 = tokenId;
        address user2 = votingEscrow.ownerOf(_tokenId2);
        vm.prank(user2);
        votingEscrow.transferFrom(user2, user, _tokenId2);
        
        vm.startPrank(user);
        vm.warp(block.timestamp+3601);
        vm.roll(block.number + 1);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId2);
        loan.requestLoan(_tokenId2, loanAmount, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false, address(usdc));
        loan.setPayoffToken(_tokenId2, true);
        loan.setTopUp(_tokenId2, true);
        vm.warp(block.timestamp+3601);
        vm.roll(block.number + 1);
        vm.stopPrank();

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        address[] memory bribes = new address[](0);
        bytes memory data = hex"84a7f3dd020100015f3454Fa53E5866a4f69bBc2E6B9A041092D9Ad70703c19d0213c8780001b31f66aa3c1e785363f0875a1b74e27b85fd66c7077938fca12e5c4e00000001ffff003a6bad9b743d658048742935fffe2b6ed7080e9c7ed08b7ac7d500018B0D80F3EDd2631962BE8aE932c7B4558f8B23650001b97ef9ef8734c71904d8002f8b6bc66dd9c48a6e043b8f775b0001037eDa3aDB1198021A9b2e88C22B464fD38db3f3000000000401030500000202030200000102001e040b0101030401ff0000000000000000008b0d80f3edd2631962be8ae932c7b4558f8b2365ffff003a6bad9b743d658048742935fffe2b6ed7a20c959b19f114e9c2d81547734cdc1110bd773db31f66aa3c1e785363f0875a1b74e27b85fd66c700000000000000000000000000000000";
        uint256[2] memory allocations = [uint256(expectedRewards), uint256(0)];
        _claimRewards(loan, tokenId, bribes, data, allocations);
        uint256 endingUserBalance = usdc.balanceOf(address(user));      
        console.log("ending user balance: %s", endingUserBalance);
        console.log("starting user balance: %s", startingUserBalance);  
        assertTrue(endingUserBalance > startingUserBalance, "User should have more than starting balance");

        (uint256 balance,) = loan.getLoanDetails(_tokenId2);
        assertTrue(balance >  1000e6, "Balance should have increased");
    }

    function testClaimWithIncreasePercentage() public {
        uint256 _tokenId = 5596;
        vm.selectFork(_fork);
        vm.startPrank(Loan(0xf6A044c3b2a3373eF2909E2474f3229f23279B5F).owner());
        Loan loanV2 = new Loan();
        Loan _loan = Loan(0xf6A044c3b2a3373eF2909E2474f3229f23279B5F);
        _loan.upgradeToAndCall(address(loanV2), new bytes(0));
        vm.stopPrank();

        (uint256 balance,) = _loan.getLoanDetails(_tokenId);
        assertEq(balance, 5026342, "should have balance");

        uint256 beginningLoanUsdcBalance = usdc.balanceOf(address(loan));
        address[] memory bribes = new address[](0);
        bytes memory data = hex"84a7f3dd03020001f052cee512c696e91625b07ecc9484fdb6d456290a06912fe77c2e008000000001152b9d0fdc40c096757f570a51e494bd4b943e5001070001d9fa522f5bc6cfa40211944f2c8da785773ad99d0001b31f66aa3c1e785363f0875a1b74e27b85fd66c70703d8071f393ade0000000149d5c2bdffac6ce2bfdb6640f4f80f226bc10bab0605c4cf050fef000142be75636374dfa0e57eb96fa7f68fe7fcdad8a30001b97ef9ef8734c71904d8002f8b6bc66dd9c48a6e080dde312cce18ee800001f6a044c3b2a3373ef2909e2474f3229f23279b5f0001aaab9d12a30504559b0c5a9a5977fee4a6081c6b041bfa733b0001f6a044c3b2a3373ef2909e2474f3229f23279b5f000000000c03040e020b03020203000425010000040501001501000006070106030009000109001e020b03000a03010600010003010000080b011e03c03020fd0000020b03010c0d0000020dff0000000000000000000000000000000000000000000000003b35f7050c99729a50e69d69e43983864934103b07d2a7663ebac17276da047670b4b465081ca6f9b31f66aa3c1e785363f0875a1b74e27b85fd66c742be75636374dfa0e57eb96fa7f68fe7fcdad8a349d5c2bdffac6ce2bfdb6640f4f80f226bc10babd9fa522f5bc6cfa40211944f2c8da785773ad99d152b9d0fdc40c096757f570a51e494bd4b943e501784b2ff6841d46163fbf817b3feb98a0e163e0facfb898cff266e53278cc0124fc2c7c94c8cb9a5a20c959b19f114e9c2d81547734cdc1110bd773d60781c2586d68229fde47564546784ab3faca982f70b1d7d9dcb99e4b9db92e2799ddfcfc2d88aabb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e00000000000000000000000000000000000000000000000000000000";
        uint256[2] memory allocations = [uint256(41349), uint256(21919478169541)];
        uint256 rewards = _claimRewards(_loan, _tokenId, bribes, data, allocations);
        uint256 endingLoanUsdcBalance = usdc.balanceOf(address(loan));
        assertEq(endingLoanUsdcBalance - beginningLoanUsdcBalance, 0, "Loan USDC balance should not change");

        (balance,) = _loan.getLoanDetails(_tokenId);
        // balance should be lower
        assertEq(balance, 5006370);
    }

    // function testClaimWithIncreasePercentage2() public {
    //     uint256 _tokenId = 5408;
    //     vm.selectFork(_fork);
    //     vm.startPrank(Loan(0xf6A044c3b2a3373eF2909E2474f3229f23279B5F).owner());
    //     Loan loanV2 = new Loan();
    //     Loan(0xf6A044c3b2a3373eF2909E2474f3229f23279B5F).upgradeToAndCall(address(loanV2), new bytes(0));
    //     vm.stopPrank();
    //     uint256 beginningLoanUsdcBalance = usdc.balanceOf(address(loan));
    //     address[] memory bribes = new address[](0);
    //     bytes memory data = hex"84a7f3dd03020001f052cee512c696e91625b07ecc9484fdb6d456290a06912fe77c2e008000000001152b9d0fdc40c096757f570a51e494bd4b943e5001070001d9fa522f5bc6cfa40211944f2c8da785773ad99d0001b31f66aa3c1e785363f0875a1b74e27b85fd66c70703d8071f393ade0000000149d5c2bdffac6ce2bfdb6640f4f80f226bc10bab0605c4cf050fef000142be75636374dfa0e57eb96fa7f68fe7fcdad8a30001b97ef9ef8734c71904d8002f8b6bc66dd9c48a6e080dde312cce18ee800001f6a044c3b2a3373ef2909e2474f3229f23279b5f0001aaab9d12a30504559b0c5a9a5977fee4a6081c6b041bfa733b0001f6a044c3b2a3373ef2909e2474f3229f23279b5f000000000c03040e020b03020203000425010000040501001501000006070106030009000109001e020b03000a03010600010003010000080b011e03c03020fd0000020b03010c0d0000020dff0000000000000000000000000000000000000000000000003b35f7050c99729a50e69d69e43983864934103b07d2a7663ebac17276da047670b4b465081ca6f9b31f66aa3c1e785363f0875a1b74e27b85fd66c742be75636374dfa0e57eb96fa7f68fe7fcdad8a349d5c2bdffac6ce2bfdb6640f4f80f226bc10babd9fa522f5bc6cfa40211944f2c8da785773ad99d152b9d0fdc40c096757f570a51e494bd4b943e501784b2ff6841d46163fbf817b3feb98a0e163e0facfb898cff266e53278cc0124fc2c7c94c8cb9a5a20c959b19f114e9c2d81547734cdc1110bd773d60781c2586d68229fde47564546784ab3faca982f70b1d7d9dcb99e4b9db92e2799ddfcfc2d88aabb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e00000000000000000000000000000000000000000000000000000000";
    //     uint256[2] memory allocations = [uint256(41349), uint256(21919478169541)];
    //     uint256 rewards = _claimRewards(Loan(0xf6A044c3b2a3373eF2909E2474f3229f23279B5F), _tokenId, bribes, data, allocations);
    //     uint256 endingLoanUsdcBalance = usdc.balanceOf(address(loan));
    // }


    function xtestTopup2() public {
        usdc.mint(address(vault), 100000e6);

        uint256 _tokenId = 3687;

        uint256 loanAmount = .1e6;

        user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, loanAmount, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false, address(usdc));

        vm.stopPrank();

        uint256 _tokenId2 = tokenId;
        address user2 = votingEscrow.ownerOf(_tokenId2);
        vm.prank(user2);
        votingEscrow.transferFrom(user2, user, _tokenId2);
        
        vm.startPrank(user);
        vm.warp(block.timestamp+1);
        vm.roll(block.number + 1);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId2);
        loan.requestLoan(_tokenId2, loanAmount, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), true, false, address(usdc));
        loan.setPayoffToken(_tokenId2, true);

        address[] memory bribes = new address[](0);
        bytes memory data = hex"84a7f3dd020100015f3454Fa53E5866a4f69bBc2E6B9A041092D9Ad70703c19d0213c8780001b31f66aa3c1e785363f0875a1b74e27b85fd66c7077938fca12e5c4e00000001ffff003a6bad9b743d658048742935fffe2b6ed7080e9c7ed08b7ac7d500018B0D80F3EDd2631962BE8aE932c7B4558f8B23650001b97ef9ef8734c71904d8002f8b6bc66dd9c48a6e043b8f775b0001037eDa3aDB1198021A9b2e88C22B464fD38db3f3000000000401030500000202030200000102001e040b0101030401ff0000000000000000008b0d80f3edd2631962be8ae932c7b4558f8b2365ffff003a6bad9b743d658048742935fffe2b6ed7a20c959b19f114e9c2d81547734cdc1110bd773db31f66aa3c1e785363f0875a1b74e27b85fd66c700000000000000000000000000000000";
        uint256[2] memory allocations = [uint256(expectedRewards), uint256(0)];
        _claimRewards(loan, tokenId, bribes, data, allocations);

        (uint256 balance,) = loan.getLoanDetails(_tokenId2);
        assertTrue(balance >  1000e6, "Balance should have increased");
    }
    function testManualVoting() public {
        uint256 _tokenId = 3687;
        usdc.mint(address(vault), 10000e6);
        uint256 amount = 1e6;
        address _user = votingEscrow.ownerOf(_tokenId);

        
        address[] memory manualPools = new address[](1);
        manualPools[0] = address(0xa20c959b19F114e9C2D81547734CdC1110bd773D);
        uint256[] memory manualWeights = new uint256[](1);
        manualWeights[0] = 100e18;

        vm.startPrank(Ownable2StepUpgradeable(loan).owner());
        loan.setApprovedPools(manualPools, true);
        vm.stopPrank();

        vm.startPrank(_user);
        votingEscrow.approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false, address(usdc));

        vm.stopPrank();


        
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 3601);
        loan.vote(_tokenId);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        vm.startPrank(_user);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId;
        loan.userVote(tokenIds, manualPools, manualWeights);
    }

    function _claimRewards(Loan _loan, uint256 _tokenId, address[] memory bribes, bytes memory tradeData, uint256[2] memory allocations) internal returns (uint256) {
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
        address[] memory fees = new address[](voterPools.length);
        address[][] memory tokens = new address[][](voterPools.length);

        for (uint256 i = 0; i < voterPools.length; i++) {
            address gauge = voter.gauges(voterPools[i]);
            fees[i] = voter.feeDistributors(gauge);
            address[] memory token = new address[](2);
            token[0] = ICLGauge(voterPools[i]).token0();
            token[1] = ICLGauge(voterPools[i]).token1();
            address[] memory bribeTokens = new address[](bribes.length + 2);
            for (uint256 j = 0; j < bribes.length; j++) {
                bribeTokens[j] = bribes[j];
            }
            bribeTokens[bribes.length] = token[0];
            bribeTokens[bribes.length + 1] = token[1];
            tokens[i] = bribeTokens;
        }
        // log fees and tokens
        console.log("Fees and Tokens for Token ID %s", _tokenId);
        for (uint256 i = 0; i < fees.length; i++) {
            console.log("Fee %s: %s", i, fees[i]);
            for (uint256 j = 0; j < tokens[i].length; j++) {
                console.log("Token %s: %s", j, tokens[i][j]);
            }
        }
        // Convert hex string to bytes

        vm.prank(0x40ac2E2891105Ea3a04CC0d8d4425fe30F38B182);
        return _loan.claim(_tokenId, fees, tokens, tradeData, allocations);
    }
}
// 1061274 + 208621 = 1279895
