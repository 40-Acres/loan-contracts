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

    uint256 expectedRewards = 1261867;

    function setUp() public {
        fork = vm.createFork(vm.envString("AVAX_RPC_URL"));
        fork2 = vm.createFork(vm.envString("AVAX_RPC_URL"));
        vm.selectFork(fork2);
        vm.rollFork(62047585);
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
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false);


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
        vm.stopPrank();
        (uint256 maxLoan,  ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 89819);
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
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

        amount = 1e6;
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > 1e6);
        assertTrue(usdc.balanceOf(address(vault)) < 100e6);

        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount);
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
    }


    function testLoanVotingAdvance() public {
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
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
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
        uint256 rewards = _claimRewards(loan, tokenId, bribes);
        assertEq(rewards, expectedRewards, "rewards should be expectedRewards");
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 169576);
    }

    function testIncreaseAmountPercentage20() public {
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
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
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
        _claimRewards(loan, tokenId, bribes);
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 169576);
    }

    function testIncreaseAmountPercentage50WithLoan() public {
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
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
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
        _claimRewards(loan, tokenId, bribes);
        nftBalance = votingEscrow.balanceOfNFTAt(tokenId, block.timestamp);
        assertTrue(nftBalance >= 994807632341109944);
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 169576);
    }


    function testIncreaseAmountPercentage100WithLoan() public {
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
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
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
        _claimRewards(loan, tokenId, bribes);
        nftBalance = votingEscrow.balanceOfNFTAt(tokenId, block.timestamp);
        assertTrue(nftBalance >= 994807632341109944);
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 169576);
    }

    function testIncreaseAmountPercentage100NoLoan() public {
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
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.InvestToVault, 0, address(0), false, false);
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
        uint256 rewardsClaimed = _claimRewards(loan, tokenId, bribes);
        assertEq(rewardsClaimed, expectedRewards);
        nftBalance = votingEscrow.balanceOfNFTAt(tokenId, block.timestamp);
        assertTrue(nftBalance >= 997150273160109328);
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should not have gained");
        assertEq(aero.balanceOf(address(owner)), 36117747185770, "owner should have gained");
        assertEq(loan.activeAssets(), 0, "should not have active assets");


        rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertEq(rewardsPerEpoch, 0, "rewardsPerEpoch should be  0");

        assertEq(vault.epochRewardsLocked(), 0);
    }

    function testIncreaseAmountPercentage75NoLoan() public {
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
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.InvestToVault, 0, address(0), false, false);
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
        uint256 rewardsClaimed = _claimRewards(loan, tokenId, bribes);
        assertEq(rewardsClaimed, expectedRewards);
        nftBalance = votingEscrow.balanceOfNFTAt(tokenId, block.timestamp);
        assertTrue(nftBalance >= 996367037369959857);
        assertEq(usdc.balanceOf(address(owner)), 3154, "owner should have gained");
        assertEq(aero.balanceOf(address(owner)), 27093227692782, "owner should have gained");
        assertEq(loan.activeAssets(), 0, "should not have active assets");


        rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertEq(rewardsPerEpoch, 0, "rewardsPerEpoch should be  0");

        assertEq(vault.epochRewardsLocked(), 0);
    }

    function testIncreaseAmountPercentage75NoLoanToCommunityToken2() public {
        user = votingEscrow.ownerOf(tokenId);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
            
        address[] memory bribes = new address[](0);

        address veOwner = votingEscrow.ownerOf(3687);
        vm.startPrank(veOwner);
        CommunityRewards _communityRewards = new CommunityRewards();
        ERC1967Proxy _proxy = new ERC1967Proxy(address(_communityRewards), "");
        vm.roll(block.number + 1);
        votingEscrow.approve(address(_proxy), 3687);
        CommunityRewards(address(_proxy)).initialize(address(loan), tokens, 0, 3687, 0xAAAEa1fB9f3DE3F70E89f37B69Ab11B47eb9Ce6F);
        vm.stopPrank();
        vm.startPrank(owner);
        loan.setManagedNft(3687);

        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertEq(rewardsPerEpoch, 0, "rewardsPerEpoch should be  0");

        uint256 startingUserBalance = usdc.balanceOf(address(user));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 0, Loanv2.ZeroBalanceOption.InvestToVault, 0, address(0), false, false);
        vm.roll(block.number+1);
        vm.warp(block.timestamp + 3601);
        loan.setIncreasePercentage(tokenId, 10000);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        loan.setOptInCommunityRewards(tokenIds, true);
        vm.stopPrank();


        CommunityRewards communityRewards = CommunityRewards(address(_proxy));
        vm.startPrank(address(loan));
        console.log(3687, _claimRewards(loan, 3687, bribes));
        vm.stopPrank();


        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 7 days);
        IMinter(0xAAA823aa799BDa3193D46476539bcb1da5B71330).updatePeriod();
        uint256 ownerShares = communityRewards.balanceOf(owner);
        console.log(3687, _claimRewards(loan, 3687, bribes));
        uint256 userBalance = usdc.balanceOf(address(user));
        assertTrue(ownerShares > 0, "owner should have shares");
        
        uint256 ownerUsdBalance = usdc.balanceOf(address(owner));
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 7 days);
        vm.prank(address(loan));
        communityRewards.notifyRewardAmount(tokens[0], 10e6);
        usdc.mint(address(communityRewards), 10e6);
        communityRewards.getRewardForUser(user, tokens);
        communityRewards.getRewardForUser(owner, tokens);

        assertTrue(usdc.balanceOf(address(owner)) > ownerUsdBalance, "owner should have more than starting balance");
    }

    function testIncreaseLoan() public {
        uint256 amount = 1e6;

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "ff");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
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
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
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


    function testReinvestVault() public {
        assertEq(usdc.balanceOf(address(vault)), 100e6, "vault should have 0 balance");
        uint256 _tokenId = 3687;

        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));
        uint256 startingVaultBalance = usdc.balanceOf(address(vault));
        
        user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, 0, Loanv2.ZeroBalanceOption.InvestToVault, 0, address(0), false, false);
        vm.roll(block.number+1);
        vm.warp(block.timestamp + 3601);
        vm.stopPrank();
        
        address[] memory bribes = new address[](0);
        _claimRewards(loan, _tokenId, bribes);

        uint256 endingOwnerBalance = usdc.balanceOf(address(owner));

        

        // owner should not receive rewards
        assertNotEq(endingOwnerBalance - startingOwnerBalance, 0, "owner should receive rewards");
        assertTrue(usdc.balanceOf(address(vault)) > startingVaultBalance, "vault should have more than starting balance");
    }


    function testPayToOwner() public {
        assertEq(usdc.balanceOf(address(vault)), 100e6, "vault should have 0 balance");
        uint256 _tokenId = 3687;

        
        user = votingEscrow.ownerOf(_tokenId);
        uint256 startingOwnerBalance = usdc.balanceOf(address(Ownable2StepUpgradeable(loan).owner()));
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingLoanBalance = usdc.balanceOf(address(loan));
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, 0, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);
        vm.roll(block.number+1);
        vm.warp(block.timestamp + 3601);
        vm.stopPrank();
        

        address[] memory bribes = new address[](0);
        _claimRewards(loan, _tokenId, bribes);

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
    }

    function testPayToOwnerPayoutToken() public {
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
        loan.requestLoan(_tokenId, 0, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);
        vm.roll(block.number+1);
        vm.warp(block.timestamp + 3601);
        vm.warp(block.timestamp+1);
        loan.setPreferredToken(_tokenId, address(weth));
        vm.stopPrank();
        

        address[] memory bribes = new address[](0);
        _claimRewards(loan, _tokenId, bribes);

        uint256 endingUserBalance = weth.balanceOf(address(user));
        uint256 endingOwnerBalance = usdc.balanceOf(address(Ownable2StepUpgradeable(loan).owner()));
        uint256 endingLoanBalance = usdc.balanceOf(address(loan));



        // owner should receive rewards in usdc 
        assertNotEq(endingOwnerBalance - startingOwnerBalance, 0, "owner should receive usd rewards");

        assertNotEq(endingUserBalance - startingUserBalance, 0,  "user should have receive weth rewards");

        assertEq(endingLoanBalance - startingLoanBalance, 0, "loan should not receive rewards");        
    }

    function testManagedNft() public {
        uint256 _tokenId = 3687;
        address _user = votingEscrow.ownerOf(_tokenId);
        vm.prank(_user);
        votingEscrow.transferFrom(_user, address(this), _tokenId);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        
        CommunityRewards _communityRewards = new CommunityRewards();
        ERC1967Proxy _proxy = new ERC1967Proxy(address(_communityRewards), "");
        votingEscrow.approve(address(_proxy), _tokenId);
        vm.roll(block.number + 1);
        CommunityRewards(address(_proxy)).initialize(address(loan), tokens, 2500e18, _tokenId, 0xAAAEa1fB9f3DE3F70E89f37B69Ab11B47eb9Ce6F);

        

        vm.prank(0xeefbd314141BF7933Be47E44C1dC1437e58604Cb);
        aero.transfer(_user, 10e18);
        vm.startPrank(_user);
        aero.approve(address(votingEscrow), 10e18);
        uint256 newLockId = votingEscrow.createLock(10e18, 604800);
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        
        address _user2 = votingEscrow.ownerOf(newLockId);
        console.log("new lock id: %s", newLockId);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        uint256 nftBalance = votingEscrow.balanceOfNFT(newLockId);
        assertTrue(nftBalance > 0, "should not have balance");
        vm.prank(_user2);
        votingEscrow.transferFrom(_user2, address(loan), newLockId);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        address _owner = Ownable2StepUpgradeable(loan).owner();
        vm.prank(_owner);
        loan.setManagedNft(3687);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        uint256 beginningBalance = votingEscrow.balanceOfNFT(_tokenId);
        vm.startPrank(_owner);
        loan.mergeIntoManagedNft(newLockId);
        assertTrue(votingEscrow.balanceOfNFT(_tokenId) > beginningBalance, "should have more balance");

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        assertEq(votingEscrow.ownerOf(newLockId), address(0), "should be burnt");
        vm.expectRevert();
        loan.setManagedNft(newLockId);

        address[] memory bribes = new address[](0);
        CommunityRewards communityRewards = CommunityRewards(address(_proxy));
        address user1 = address(0x353641);
        address user2 = address(0x26546);
        vm.startPrank(address(loan));
        communityRewards.deposit(uint256(3687), 10e18, user1);
        communityRewards.deposit(uint256(3687), 10e18, user2);
        vm.stopPrank();


        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 7 days);


        IMinter(0xAAA823aa799BDa3193D46476539bcb1da5B71330).updatePeriod();
        _claimRewards(loan, _tokenId, bribes);
        uint256 rewards = communityRewards.tokenRewardsPerEpoch(address(usdc), ProtocolTimeLibrary.epochStart(block.timestamp) - ProtocolTimeLibrary.WEEK);
        assertTrue(rewards > 0, "rewards should be greater than 0");
        console.log(usdc.balanceOf(address(user1)));
        communityRewards.getRewardForUser(user1, tokens);
        communityRewards.getRewardForUser(user2, tokens);
        console.log(usdc.balanceOf(address(user1)));




        assertTrue(IERC20(address(usdc)).balanceOf(address(communityRewards)) <  10, "should be less than 10");

        // test setting increase percentage
        vm.expectRevert();
        communityRewards.setIncreasePercentage(0);
        
        vm.startPrank(_owner);
        communityRewards.setIncreasePercentage(0);
    }

    function testManagedNft2() public {
        uint256 _tokenId = 3687;
        address _user = votingEscrow.ownerOf(_tokenId);
        vm.prank(_user);
        votingEscrow.transferFrom(_user, address(this), _tokenId);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        
        CommunityRewards _communityRewards = new CommunityRewards();
        ERC1967Proxy _proxy = new ERC1967Proxy(address(_communityRewards), "");
        votingEscrow.approve(address(_proxy), _tokenId);
        vm.roll(block.number + 1);
        CommunityRewards(address(_proxy)).initialize(address(loan), tokens, 2500e18, _tokenId, 0xAAAEa1fB9f3DE3F70E89f37B69Ab11B47eb9Ce6F);

        

        vm.prank(0xeefbd314141BF7933Be47E44C1dC1437e58604Cb);
        aero.transfer(_user, 10e18);
        vm.startPrank(_user);
        aero.approve(address(votingEscrow), 10e18);
        uint256 newLockId = votingEscrow.createLock(10e18, 604800);
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        
        address _user2 = votingEscrow.ownerOf(newLockId);
        console.log("new lock id: %s", newLockId);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        uint256 nftBalance = votingEscrow.balanceOfNFT(newLockId);
        assertTrue(nftBalance > 0, "should not have balance");
        vm.prank(_user2);
        votingEscrow.transferFrom(_user2, address(loan), newLockId);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        address _owner = Ownable2StepUpgradeable(loan).owner();
        vm.prank(_owner);
        loan.setManagedNft(3687);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        uint256 beginningBalance = votingEscrow.balanceOfNFT(_tokenId);
        vm.startPrank(_owner);
        loan.mergeIntoManagedNft(newLockId);
        assertTrue(votingEscrow.balanceOfNFT(_tokenId) > beginningBalance, "should have more balance");

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        assertEq(votingEscrow.ownerOf(newLockId), address(0), "should be burnt");
        vm.expectRevert();
        loan.setManagedNft(newLockId);

        address[] memory bribes = new address[](0);
        CommunityRewards communityRewards = CommunityRewards(address(_proxy));
        address user1 = address(0x353641);
        address user2 = address(0x26546);
        vm.startPrank(address(loan));
        communityRewards.deposit(uint256(3687), 10e18, user1);
        communityRewards.deposit(uint256(3687), 10e18, user2);
        vm.stopPrank();


        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 7 days);

        IMinter(0xAAA823aa799BDa3193D46476539bcb1da5B71330).updatePeriod();
        _claimRewards(loan, _tokenId, bribes);
        uint256 rewards = communityRewards.tokenRewardsPerEpoch(address(usdc), ProtocolTimeLibrary.epochStart(block.timestamp) - ProtocolTimeLibrary.WEEK);
        assertTrue(rewards > 0, "rewards should be greater than 0");
       
        communityRewards.getRewardForUser(user1, tokens);
        communityRewards.getRewardForUser(user2, tokens);

        assertTrue(IERC20(address(usdc)).balanceOf(address(communityRewards)) <  10, "should be less than 10");

        // test setting increase percentage
        vm.expectRevert();
        communityRewards.setIncreasePercentage(0);
        
        vm.startPrank(_owner);
        communityRewards.setIncreasePercentage(0);
    }


    function testMerge() public {
        uint256 _tokenId = 3687;
        address _user = votingEscrow.ownerOf(tokenId);
        vm.startPrank(_user);        
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 0, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), true, false);
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

    function testPayoffToken() public {
        usdc.mint(address(vault), 100000e6);

        uint256 _tokenId = 3687;
        uint256 _tokenId2 = tokenId;

        uint256 loanAmount = .1e6;

        user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, loanAmount, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);

        vm.stopPrank();

        address user2 = votingEscrow.ownerOf(_tokenId2);
        vm.prank(user2);
        votingEscrow.transferFrom(user2, user, _tokenId2);
        
        vm.startPrank(user);
        vm.warp(block.timestamp+1);
        vm.roll(block.number + 1);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId2);
        loan.requestLoan(_tokenId2, loanAmount, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);
        loan.setPayoffToken(_tokenId2, true);


        address[] memory bribes = new address[](0);
        _claimRewards(loan, _tokenId, bribes);


        (uint256 balance,) = loan.getLoanDetails(_tokenId2);
        console.log("balance: %s", balance);
        console.log("loanAmount: %s", loanAmount);
        assertTrue(balance < loanAmount, "Balance should be less than amount");
        (balance,) = loan.getLoanDetails(_tokenId);
        assertEq(balance, 0, "Balance should be 0");
    }

    function testPayoffTokenMoreBalance() public {

        usdc.mint(address(vault), 100000e6);

        uint256 _tokenId = tokenId;
        uint256 _tokenId2 = 3687;


        uint256 loanAmount = 2e6;

        user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, loanAmount, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);

        vm.stopPrank();

        address user2 = votingEscrow.ownerOf(_tokenId2);
        vm.prank(user2);
        votingEscrow.transferFrom(user2, user, _tokenId2);
        
        vm.startPrank(user);
        vm.warp(block.timestamp+1);
        vm.roll(block.number + 1);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId2);
        loan.requestLoan(_tokenId2, loanAmount, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);
        loan.setPayoffToken(_tokenId2, true);


        address[] memory bribes = new address[](0);
        _claimRewards(loan, _tokenId, bribes);


        (uint256 balance,) = loan.getLoanDetails(_tokenId2);
        console.log("balance: %s", balance);
        assertTrue(balance < loanAmount, "Balance should be less than amount");
        (balance,) = loan.getLoanDetails(_tokenId);
        assertNotEq(balance, 0, "Balance should not be 0");
    }

    function testIncreaseAmountPercentage52() public {
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
        loan.requestLoan(tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
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
        uint256 rewards = _claimRewards(loan, tokenId, bribes);
        assertEq(rewards, 1261867, "rewards should be 957174473");
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 169576);
    }

    function testTopup() public {
        usdc.mint(address(vault), 100000e6);

        uint256 _tokenId = 3687;

        uint256 loanAmount = .1e6;

        user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, loanAmount, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);

        vm.stopPrank();

        uint256 _tokenId2 = tokenId;
        address user2 = votingEscrow.ownerOf(_tokenId2);
        vm.prank(user2);
        votingEscrow.transferFrom(user2, user, _tokenId2);
        
        vm.startPrank(user);
        vm.warp(block.timestamp+3601);
        vm.roll(block.number + 1);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId2);
        loan.requestLoan(_tokenId2, loanAmount, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);
        loan.setPayoffToken(_tokenId2, true);
        loan.setTopUp(_tokenId2, true);
        vm.warp(block.timestamp+3601);
        vm.roll(block.number + 1);
        vm.stopPrank();

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        address[] memory bribes = new address[](0);
        _claimRewards(loan, _tokenId, bribes);
        uint256 endingUserBalance = usdc.balanceOf(address(user));      
        console.log("ending user balance: %s", endingUserBalance);
        console.log("starting user balance: %s", startingUserBalance);  
        assertTrue(endingUserBalance > startingUserBalance, "User should have more than starting balance");

        (uint256 balance,) = loan.getLoanDetails(_tokenId2);
        assertTrue(balance >  1000e6, "Balance should have increased");
    }


    function testTopup2() public {
        usdc.mint(address(vault), 100000e6);

        uint256 _tokenId = 3687;

        uint256 loanAmount = .1e6;

        user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, loanAmount, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);

        vm.stopPrank();

        uint256 _tokenId2 = tokenId;
        address user2 = votingEscrow.ownerOf(_tokenId2);
        vm.prank(user2);
        votingEscrow.transferFrom(user2, user, _tokenId2);
        
        vm.startPrank(user);
        vm.warp(block.timestamp+1);
        vm.roll(block.number + 1);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId2);
        loan.requestLoan(_tokenId2, loanAmount, Loanv2.ZeroBalanceOption.PayToOwner, 0, address(0), true, false);
        loan.setPayoffToken(_tokenId2, true);

        address[] memory bribes = new address[](0);
        _claimRewards(loan, _tokenId, bribes);


        (uint256 balance,) = loan.getLoanDetails(_tokenId2);
        assertTrue(balance >  1000e6, "Balance should have increased");
    }


    function testManualVoting() public {
        uint256 _tokenId = 3687;
        usdc.mint(address(vault), 10000e6);
        uint256 amount = 1e6;
        address _user = votingEscrow.ownerOf(_tokenId);

        uint256 lastVoteTimestamp = voter.lastVoted(_tokenId);
        
        address[] memory manualPools = new address[](1);
        manualPools[0] = address(0xa20c959b19F114e9C2D81547734CdC1110bd773D);
        uint256[] memory manualWeights = new uint256[](1);
        manualWeights[0] = 100e18;

        vm.startPrank(Ownable2StepUpgradeable(loan).owner());
        loan.setApprovedPools(manualPools, true);
        vm.stopPrank();

        vm.startPrank(_user);
        votingEscrow.approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, amount, Loanv2.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

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

    function _claimRewards(Loan _loan, uint256 _tokenId, address[] memory bribes) internal returns (uint256) {
        vm.selectFork(fork2);
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
        vm.selectFork(fork);
        bytes memory data = "";
        uint256[2] memory allocations = [uint256(0), uint256(0)];
        _loan.claim(_tokenId, fees, tokens, data, allocations);
        return 0;
    }
}
