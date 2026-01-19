// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/LoanV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/VaultV2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotingEscrow } from "../src/interfaces/IVotingEscrow.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ProtocolTimeLibrary } from "src/libraries/ProtocolTimeLibrary.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {BaseDeploy} from "../script/BaseDeploy.s.sol";
import {BaseUpgrade} from "../script/BaseUpgrade.s.sol";
import {DeploySwapper} from "../script/BaseDeploySwapper.s.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ICLGauge} from "src/interfaces/ICLGauge.sol";
import {MockPortfolioFactory} from "./mocks/MockAccountStorage.sol";
import { Swapper } from "../src/Swapper.sol";
import {CommunityRewards} from "../src/CommunityRewards/CommunityRewards.sol";
import { IMinter } from "src/interfaces/IMinter.sol";
import { MockOdosRouterRL } from "./mocks/MockOdosRouter.sol";

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


contract LoanTest is Test {
    uint256 fork;

    IERC20 aero = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    address[] pool = [address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59)];
    ProxyAdmin admin;

    // deployed contracts
    Vault vault;
    Loan public loan;
    address owner;
    address user;
    uint256 tokenId = 64196;

    uint256 expectedRewards = 957174473;

    Swapper public swapper;
    MockOdosRouterRL public mockRouter;

    function setUp() public {
        fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(24353746);
        owner = vm.addr(0x123);
        user = votingEscrow.ownerOf(tokenId);
        BaseDeploy deployer = new BaseDeploy();
        (loan, vault) = deployer.deployLoan();

        vm.startPrank(address(deployer));
        loan.setMultiplier(100000000000);
        loan.setRewardsRate(11300);
        loan.setLenderPremium(2000);
        loan.setProtocolFee(500); // 5% protocol fee
        IOwnable(address(loan)).transferOwnership(owner);
        DeploySwapper swapperDeploy = new DeploySwapper();
        swapper = Swapper(swapperDeploy.deploy());
        loan.setSwapper(address(swapper));
        vm.stopPrank();

        vm.prank(owner);
        IOwnable(address(loan)).acceptOwnership();

        // allow this test contract to mint USDC
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(voter), 100e6);
        usdc.mint(address(vault), 100e6);

        // Deploy MockOdosRouterRL
        MockOdosRouterRL mockRouter = new MockOdosRouterRL();
        mockRouter.initMock(address(this));

        address odosRouterAddress = loan.odosRouter();
        vm.allowCheatcodes(odosRouterAddress);
        vm.etch(odosRouterAddress, address(mockRouter).code);
        MockOdosRouterRL(odosRouterAddress).initMock(address(this));
        vm.stopPrank();
    }

    function testOwner() public view {
        address o = loan.owner();
        assertEq(o, owner);
    }


    function testGetMaxLoan() public {
        (uint256 maxLoan,  ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 80e6);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        uint256 amount = 5e6;
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);


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



    
    function testMaxLoan() public {
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
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

        amount = 1e6;
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
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
        tokenId = 524;
        user = votingEscrow.ownerOf(tokenId);

        uint256 amount = 1e6;
        
    
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.roll(block.number+1);
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
        uint256 rewards = 0; //// _claimRewards(loan, tokenId, bribes);
        assertEq(rewards, expectedRewards, "rewards should be expectedRewards");
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 93053);
    }

    function xtestIncreaseAmountPercentage20() public {
        tokenId = 524;
        user = votingEscrow.ownerOf(tokenId);

        uint256 amount = 1e6;
        
    
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.roll(block.number+1);
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
        // _claimRewards(loan, tokenId, bribes);
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 93053);
    }

    function xtestIncreaseAmountPercentage50WithLoan() public {
        tokenId = 524;
        user = votingEscrow.ownerOf(tokenId);

        uint256 amount = 1e6;
        
    
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.roll(block.number+1);
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
        // _claimRewards(loan, tokenId, bribes);
        nftBalance = votingEscrow.balanceOfNFTAt(tokenId, block.timestamp);
        assertEq(nftBalance, 82986787141255418435959);
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 93053);
    }


    function xtestIncreaseAmountPercentage100WithLoan() public {
        tokenId = 524;
        user = votingEscrow.ownerOf(tokenId);

        uint256 amount = 1e6;
        
    
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.roll(block.number+1);
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
        // _claimRewards(loan, tokenId, bribes);
        nftBalance = votingEscrow.balanceOfNFTAt(tokenId, block.timestamp);
        assertEq(nftBalance, 82986787141255418435959);
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 93053);
    }

    function xtestIncreaseAmountPercentage100NoLoan() public {
        tokenId = 524;
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
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.InvestToVault, 0, address(0), false, false);
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
        uint256 rewardsClaimed = 0; // // _claimRewards(loan, tokenId, bribes);
        assertEq(rewardsClaimed, expectedRewards);
        nftBalance = votingEscrow.balanceOfNFTAt(tokenId, block.timestamp);
        assertEq(nftBalance, 83458838569360261965804);
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should not have gained");
        assertEq(aero.balanceOf(address(owner)), 6379101213779619486, "owner should have gained");
        assertEq(loan.activeAssets(), 0, "should not have active assets");


        rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertEq(rewardsPerEpoch, 0, "rewardsPerEpoch should be  0");

        assertEq(vault.epochRewardsLocked(), 0);
    }

    function xtestIncreaseAmountPercentage75NoLoan() public {
        tokenId = 524;
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
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.InvestToVault, 0, address(0), false, false);
        vm.roll(block.number+1);
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
        uint256 rewardsClaimed = 0; // // _claimRewards(loan, tokenId, bribes);
        assertEq(rewardsClaimed, expectedRewards);
        nftBalance = votingEscrow.balanceOfNFTAt(tokenId, block.timestamp);
        assertEq(nftBalance, 83300957854737558566864);
        assertEq(usdc.balanceOf(address(owner)), 2392936, "owner should have gained");
        assertEq(aero.balanceOf(address(owner)), 4784346520620999294, "owner should have gained");
        assertEq(loan.activeAssets(), 0, "should not have active assets");


        rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertEq(rewardsPerEpoch, 0, "rewardsPerEpoch should be  0");

        assertEq(vault.epochRewardsLocked(), 0);
    }
    


    function xtestIncreaseAmountPercentage75NoLoanToCommunityToken2() public {
        user = votingEscrow.ownerOf(524);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
            
        address[] memory bribes = new address[](0);

        address veOwner = votingEscrow.ownerOf(318);
        vm.startPrank(veOwner);
        CommunityRewards _communityRewards = new CommunityRewards();
        ERC1967Proxy _proxy = new ERC1967Proxy(address(_communityRewards), "");
        vm.roll(block.number + 1);
        votingEscrow.approve(address(_proxy), 318);
        CommunityRewards(address(_proxy)).initialize(address(loan), tokens, 0, 318, 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
        vm.stopPrank();
        vm.startPrank(owner);
        loan.setManagedNft(318);

        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertEq(rewardsPerEpoch, 0, "rewardsPerEpoch should be  0");

        uint256 startingUserBalance = usdc.balanceOf(address(user));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), 524);
        loan.requestLoan(524, 0, Loan.ZeroBalanceOption.InvestToVault, 0, address(0), false, false);
        vm.roll(block.number+1);
        loan.setIncreasePercentage(524, 10000);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 524;
        loan.setOptInCommunityRewards(tokenIds, true);
        vm.stopPrank();


        CommunityRewards communityRewards = CommunityRewards(address(_proxy));
        vm.startPrank(address(loan));
       //  console.log(524, _claimRewards(loan, 524, bribes));
        vm.stopPrank();


        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 7 days);
        IMinter(0xeB018363F0a9Af8f91F06FEe6613a751b2A33FE5).updatePeriod();
        uint256 ownerShares = communityRewards.balanceOf(owner);
        // console.log(318, _claimRewards(loan, 318, bribes));
        uint256 userBalance = usdc.balanceOf(address(user));
        assertTrue(usdc.balanceOf(address(user)) > ownerShares, "owner should have shares");
        
        uint256 ownerUsdBalance = usdc.balanceOf(address(owner));
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 7 days);
        vm.prank(address(loan));
        communityRewards.notifyRewardAmount(tokens[0], 10e6);
        usdc.mint(address(communityRewards), 10e6);
        communityRewards.getRewardForUser(user, tokens);
        communityRewards.getRewardForUser(owner, tokens);

        assertTrue(usdc.balanceOf(address(user)) > userBalance, "user should have more than starting balance");
        assertTrue(usdc.balanceOf(address(owner)) > ownerUsdBalance, "owner should have more than starting balance");
    }

    function xtestIncreaseLoan() public {
        uint256 amount = 1e6;

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "ff");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.roll(block.number+1);
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
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(user)), 1e6+startingUserBalance, "User should have 1e6");
        assertEq(usdc.balanceOf(address(vault)), 99e6, "Loan should have 97e6");

        assertEq(votingEscrow.ownerOf(tokenId), address(loan));

        vm.startPrank(user);
        usdc.approve(address(loan), 5e6);
        loan.pay(tokenId, 0);
        loan.claimCollateral(tokenId);
        vm.stopPrank();

        assertEq(votingEscrow.ownerOf(tokenId), address(user));
    }


    function testBasicClaim() public {
        uint256 _tokenId = 932;
        uint256 _fork;
        _fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(_fork);
        vm.rollFork(31911971);
        
        
        vm.startPrank(Loan(0x87f18b377e625b62c708D5f6EA96EC193558EFD0).owner());
        Loan loanV2 = new Loan();
        Loan _loan = Loan(0x87f18b377e625b62c708D5f6EA96EC193558EFD0);
        _loan.upgradeToAndCall(address(loanV2), new bytes(0));
        // Set AccountStorage to mock to avoid contract call issues
        MockPortfolioFactory mockAccountStorage = new MockPortfolioFactory();
        _loan.setPortfolioFactory(address(mockAccountStorage));
        vm.stopPrank();


        // Set up mock OdosRouter at the canonical address AFTER fork is selected
        address odosRouterAddress = _loan.odosRouter();
        MockOdosRouterRL mockRouter = new MockOdosRouterRL();
        bytes memory code = address(mockRouter).code;
        vm.allowCheatcodes(odosRouterAddress);
        vm.etch(odosRouterAddress, code);
        MockOdosRouterRL(odosRouterAddress).initMock(address(this));
        // get owner of token
        address user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(_loan), _tokenId);
        _loan.requestLoan(_tokenId, 0, Loan.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);
        vm.stopPrank();
        (uint256 balance,) = _loan.getLoanDetails(_tokenId);
        assertEq(balance, 0, "should have no balance");

        uint256 beginningLoanUsdcBalance = usdc.balanceOf(address(_loan));
        uint256 beginningUserUsdcBalance = usdc.balanceOf(address(user));
        address[] memory bribes = new address[](0);
        bytes memory data = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            address(aero),
            address(usdc),
            0,
            41349,
            address(_loan)
        );
        uint256[2] memory allocations = [uint256(41349), uint256(0)];
        uint256 rewards = _claimRewards(_loan, _tokenId, bribes, data, allocations);
        uint256 endingLoanUsdcBalance = usdc.balanceOf(address(_loan));
        assertEq(endingLoanUsdcBalance - beginningLoanUsdcBalance, 0, "Loan USDC balance should not change");

        uint256 endingUserUsdcBalance = usdc.balanceOf(address(user));
        assertTrue(endingUserUsdcBalance > beginningUserUsdcBalance, "User USDC balance should increase");
        (balance,) = _loan.getLoanDetails(_tokenId);
        // balance should be lower
        // assertEq(balance, 5006370);
    }



    // test successful claim using odos v3 router
    function testBasicClaimOdosV3() public {
        uint256 _tokenId = 113;
        uint256 _fork;
        _fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(_fork);
        vm.rollFork(40262232);
        
        
        vm.startPrank(Loan(0x87f18b377e625b62c708D5f6EA96EC193558EFD0).owner());
        Loan loanV2 = new Loan();
        Loan _loan = Loan(0x87f18b377e625b62c708D5f6EA96EC193558EFD0);
        _loan.upgradeToAndCall(address(loanV2), new bytes(0));
        // Set AccountStorage to mock to avoid contract call issues
        MockPortfolioFactory mockAccountStorage = new MockPortfolioFactory();
        _loan.setPortfolioFactory(address(mockAccountStorage));
        vm.stopPrank();


        // set users increase percentage to 0
        (, address borrower) = _loan.getLoanDetails(_tokenId);
        vm.startPrank(borrower);
        _loan.setIncreasePercentage(_tokenId, 0);
        vm.stopPrank();
        // get owner of token
        address user = votingEscrow.ownerOf(_tokenId);
        (uint256 balance,) = _loan.getLoanDetails(_tokenId);

        uint256 beginningLoanUsdcBalance = usdc.balanceOf(address(_loan));
        uint256 beginningUserUsdcBalance = usdc.balanceOf(address(user));
        address[] memory bribes = new address[](0);
        bytes memory data = hex"83bd37f9000142000000000000000000000000000000000000060001833589fcd6edb6e08f4c7c32d4f71b54bda02913060169786d70680214804ccccc0001bF44De8fc9EEEED8615b0b3bc095CB0ddef35e090000000187f18b377e625b62c708D5f6EA96EC193558EFD00000000000000000000301020300080101010201ff000000000000000000000000000000000000000000482fe995c4a52bc79271ab29a53591363ee30a894200000000000000000000000000000000000006000000000000000000000000000000000000000000000000";
        uint256[2] memory allocations = [uint256(500), uint256(0)];
        uint256 rewards = _claimRewards(_loan, _tokenId, bribes, data, allocations);
        uint256 endingLoanUsdcBalance = usdc.balanceOf(address(_loan));
        assertEq(endingLoanUsdcBalance - beginningLoanUsdcBalance, 0, "Loan USDC balance should not change");

    }

    function testClaimTwoTokensWithPayoffToken() public {
        uint256 _fork;
        _fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(_fork);
        vm.rollFork(31911971);
        
        vm.startPrank(Loan(0x87f18b377e625b62c708D5f6EA96EC193558EFD0).owner());
        Loan loanV2 = new Loan();
        Loan _loan = Loan(0x87f18b377e625b62c708D5f6EA96EC193558EFD0);
        _loan.upgradeToAndCall(address(loanV2), new bytes(0));
        // Set AccountStorage to mock to avoid contract call issues
        MockPortfolioFactory mockAccountStorage = new MockPortfolioFactory();
        _loan.setPortfolioFactory(address(mockAccountStorage));
        vm.stopPrank();

        // Set up mock OdosRouter at the canonical address AFTER fork is selected
        address odosRouterAddress = _loan.odosRouter();
        MockOdosRouterRL mockRouter = new MockOdosRouterRL();
        bytes memory code = address(mockRouter).code;
        vm.allowCheatcodes(odosRouterAddress);
        vm.etch(odosRouterAddress, code);
        MockOdosRouterRL(odosRouterAddress).initMock(address(this));

        // Create a user address
        address user = vm.addr(0x1234);
        
        // Deal AERO tokens to user for creating locks
        deal(address(aero), user, 10000e18);
        
        // Create first lock with a longer duration for more voting power
        vm.startPrank(user);
        aero.approve(address(votingEscrow), type(uint256).max);
        uint256 tokenId1 = votingEscrow.createLock(1000e18, 4 * 365 days);
        vm.roll(block.number + 1);
        vm.stopPrank();
        
        // Create second lock with a longer duration for more voting power
        vm.startPrank(user);
        uint256 tokenId2 = votingEscrow.createLock(1000e18, 4 * 365 days);
        vm.roll(block.number + 1);
        vm.stopPrank();

        // Ensure vault has enough USDC for loans
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(_loan._vault(), 1000e6);


        // Check max loan for each token and request loans with balances
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(_loan), tokenId1);
        (uint256 maxLoan1,) = _loan.getMaxLoan(tokenId1);
        // Use a safe fraction of max loan (30% to be conservative)
        uint256 loanAmount1 = maxLoan1 > 0 ? (maxLoan1 * 30) / 100 : 0;
        require(loanAmount1 > 0, "Token1 has no max loan available");
        _loan.requestLoan(tokenId1, loanAmount1, Loan.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);
        vm.stopPrank();
        
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(_loan), tokenId2);
        (uint256 maxLoan2,) = _loan.getMaxLoan(tokenId2);
        require(maxLoan1 + maxLoan2 > 10e6);
        // Use a safe fraction of max loan (30% to be conservative)
        uint256 loanAmount2 = maxLoan2 > 0 ? (maxLoan2 * 30) / 100 : 0;
        require(loanAmount2 > 0, "Token2 has no max loan available");
        _loan.requestLoan(tokenId2, loanAmount2, Loan.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);
        // Set token2 as payoff token
        _loan.setPayoffToken(tokenId2, true);
        vm.stopPrank();

        // Verify both tokens have balances
        (uint256 balance1,) = _loan.getLoanDetails(tokenId1);
        (uint256 balance2,) = _loan.getLoanDetails(tokenId2);
        assertTrue(balance1 > 0, "Token1 should have balance");
        assertTrue(balance2 > 0, "Token2 should have balance");

        // Get initial balances AFTER loans are requested (so vault balance reflects loan disbursements)
        uint256 beginningVaultBalance = usdc.balanceOf(_loan._vault());
        uint256 beginningOwnerBalance = usdc.balanceOf(address(_loan.owner()));
        (uint256 beginningBalance1,) = _loan.getLoanDetails(tokenId1);
        (uint256 beginningBalance2,) = _loan.getLoanDetails(tokenId2);

        // Each token earns 100e6 USDC
        uint256 rewardsPerToken = 5e6;
        
        // Claim token1 (not payoff token)
        address[] memory bribes = new address[](0);
        bytes memory data1 = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            address(aero),
            address(usdc),
            0,
            rewardsPerToken,
            address(_loan)
        );
        uint256[2] memory allocations1 = [uint256(rewardsPerToken), uint256(0)];
        _claimRewards(_loan, tokenId1, bribes, data1, allocations1);

        // Claim token2 (payoff token)
        bytes memory data2 = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            address(aero),
            address(usdc),
            0,
            rewardsPerToken,
            address(_loan)
        );
        uint256[2] memory allocations2 = [uint256(rewardsPerToken), uint256(0)];
        _claimRewards(_loan, tokenId2, bribes, data2, allocations2);

        // Calculate expected distributions based on fee eligible amounts
        // For token1: feeEligible = min(100e6, balance1 + balance2)
        // For token2: feeEligible = min(100e6, balance2) since payoffToken is token2 itself
        uint256 feeEligibleToken1 = rewardsPerToken;
        if (rewardsPerToken > beginningBalance1 + beginningBalance2) {
            feeEligibleToken1 = beginningBalance1 + beginningBalance2;
        }
        
        uint256 feeEligibleToken2 = rewardsPerToken;
        if (rewardsPerToken > beginningBalance2) {
            feeEligibleToken2 = beginningBalance2;
        }
        
        
        // Verify token balances
        (uint256 endingBalance1,) = _loan.getLoanDetails(tokenId1);
        (uint256 endingBalance2,) = _loan.getLoanDetails(tokenId2);
        
        // Token1 (non-payoff token) balance should stay the same
        assertEq(endingBalance1, beginningBalance1, "Token1 balance should not change (not a payoff token)");
        assertLe(endingBalance2, beginningBalance2 - 5e6, "Token2 balance should decrease by more than token2s rewards");
        

        // owne rbalance should increase by 5% of rewards
        uint256 endingOwnerBalance = usdc.balanceOf(address(_loan.owner()));
        uint256 difference = endingOwnerBalance - beginningOwnerBalance;
        assertEq(difference, 832142, "Owner balance should increase by 5% of rewards for both tokens and protocol fee");
    }


    function testClaimTwoTokensWithPayoffTokenNoLoan() public {
        uint256 _fork;
        _fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(_fork);
        vm.rollFork(31911971);
        
        vm.startPrank(Loan(0x87f18b377e625b62c708D5f6EA96EC193558EFD0).owner());
        Loan loanV2 = new Loan();
        Loan _loan = Loan(0x87f18b377e625b62c708D5f6EA96EC193558EFD0);
        _loan.upgradeToAndCall(address(loanV2), new bytes(0));
        // Set AccountStorage to mock to avoid contract call issues
        MockPortfolioFactory mockAccountStorage = new MockPortfolioFactory();
        _loan.setPortfolioFactory(address(mockAccountStorage));
        vm.stopPrank();

        // Set up mock OdosRouter at the canonical address AFTER fork is selected
        address odosRouterAddress = _loan.odosRouter();
        MockOdosRouterRL mockRouter = new MockOdosRouterRL();
        bytes memory code = address(mockRouter).code;
        vm.allowCheatcodes(odosRouterAddress);
        vm.etch(odosRouterAddress, code);
        MockOdosRouterRL(odosRouterAddress).initMock(address(this));

        // Create a user address
        address user = vm.addr(0x1234);
        
        // Deal AERO tokens to user for creating locks
        deal(address(aero), user, 10000e18);
        
        // Create first lock with a longer duration for more voting power
        vm.startPrank(user);
        aero.approve(address(votingEscrow), type(uint256).max);
        uint256 tokenId1 = votingEscrow.createLock(1000e18, 4 * 365 days);
        vm.roll(block.number + 1);
        vm.stopPrank();
        
        // Create second lock with a longer duration for more voting power
        vm.startPrank(user);
        uint256 tokenId2 = votingEscrow.createLock(1000e18, 4 * 365 days);
        vm.roll(block.number + 1);
        vm.stopPrank();

        // Ensure vault has enough USDC for loans
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(_loan._vault(), 1000e6);


        // Check max loan for each token and request loans with balances
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(_loan), tokenId1);
        (uint256 maxLoan1,) = _loan.getMaxLoan(tokenId1);
        _loan.requestLoan(tokenId1, 0, Loan.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);
        vm.stopPrank();
        
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(_loan), tokenId2);
        (uint256 maxLoan2,) = _loan.getMaxLoan(tokenId2);
        require(maxLoan1 + maxLoan2 > 10e6);
        // Use a safe fraction of max loan (30% to be conservative)
        uint256 loanAmount2 = maxLoan2 > 0 ? (maxLoan2 * 30) / 100 : 0;
        require(loanAmount2 > 0, "Token2 has no max loan available");
        _loan.requestLoan(tokenId2, loanAmount2, Loan.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);
        // Set token2 as payoff token
        _loan.setPayoffToken(tokenId2, true);
        vm.stopPrank();

        // Verify both tokens have balances
        (uint256 balance1,) = _loan.getLoanDetails(tokenId1);
        (uint256 balance2,) = _loan.getLoanDetails(tokenId2);
        assertTrue(balance1 == 0, "Token1 should have no balance");
        assertTrue(balance2 > 0, "Token2 should have balance");

        // Get initial balances AFTER loans are requested (so vault balance reflects loan disbursements)
        uint256 beginningVaultBalance = usdc.balanceOf(_loan._vault());
        uint256 beginningOwnerBalance = usdc.balanceOf(address(_loan.owner()));
        (uint256 beginningBalance1,) = _loan.getLoanDetails(tokenId1);
        (uint256 beginningBalance2,) = _loan.getLoanDetails(tokenId2);

        console.log("beginning balance2: ", beginningBalance2);
        // Each token earns 5e6 USDC
        uint256 rewardsPerToken = 5e6;

        // Get initial rewardsPerEpoch
        uint256 beginningRewardsPerEpoch = _loan.lastEpochReward();

        // Claim token1 (not payoff token)
        address[] memory bribes = new address[](0);
        bytes memory data1 = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            address(aero),
            address(usdc),
            0,
            rewardsPerToken,
            address(_loan)
        );
        uint256[2] memory allocations1 = [uint256(rewardsPerToken), uint256(0)];
        _claimRewards(_loan, tokenId1, bribes, data1, allocations1);

        // Token1 has no loan but payoff token is set, so rewards go to pay off token2's loan
        uint256 vaultAfterToken1 = usdc.balanceOf(_loan._vault());
        assertGt(
            vaultAfterToken1,
            beginningVaultBalance,
            "Vault balance should increase since token1's rewards pay off token2's loan"
        );
        (uint256 midBalance1,) = _loan.getLoanDetails(tokenId1);
        assertEq(midBalance1, beginningBalance1, "Token1 balance should stay 0 (has no loan)");

        // Token2's loan balance should decrease after token1's claim (since token1's rewards pay off token2)
        (uint256 midBalance2,) = _loan.getLoanDetails(tokenId2);
        assertLt(midBalance2, beginningBalance2, "Token2 balance should decrease from token1's rewards");

        // rewardsPerEpoch should not change when claiming a token with no loan
        uint256 midRewardsPerEpoch = _loan.lastEpochReward();
        assertEq(midRewardsPerEpoch, beginningRewardsPerEpoch, "rewardsPerEpoch should not change for token with no loan");

        // Claim token2 (payoff token)
        bytes memory data2 = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwap.selector,
            address(aero),
            address(usdc),
            0,
            rewardsPerToken,
            address(_loan)
        );
        uint256[2] memory allocations2 = [uint256(rewardsPerToken), uint256(0)];
        _claimRewards(_loan, tokenId2, bribes, data2, allocations2);
        
        // Verify token balances
        (uint256 endingBalance1,) = _loan.getLoanDetails(tokenId1);
        (uint256 endingBalance2,) = _loan.getLoanDetails(tokenId2);
        console.log("ending balance2: ", endingBalance2);
        
        // Token1 (non-payoff token) balance should stay the same
        assertEq(endingBalance1, beginningBalance1, "Token1 balance should not change (not a payoff token)");
        assertLe(endingBalance2, beginningBalance2 - 5e6, "Token2 balance should decrease by more than token2s rewards");
        

        // owner balance should increase by protocol fees
        // Token1 (no loan): fee on portion going to payoff token
        // Token2 (payoff token): 5% protocol fee = 250,000
        uint256 endingOwnerBalance = usdc.balanceOf(address(_loan.owner()));
        uint256 difference = endingOwnerBalance - beginningOwnerBalance;
        // Expected: protocol fees from both claims (at least 5% of one token's rewards = 250,000)
        assertGt(difference, 500000, "Owner balance should increase by protocol fees from both tokens");



        // rewardsPerEpoch should not change when claiming a token with no loan
        uint256 endingRewardsPerEpoch = _loan.lastEpochReward();
        assertGt(endingRewardsPerEpoch, beginningRewardsPerEpoch, "rewardsPerEpoch should increase for token with loan");
    }

    function testClaimPreferredToken() public {
        uint256 _tokenId = 932;
        uint256 _fork;
        _fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(_fork);
        vm.rollFork(31911971);
        vm.startPrank(Loan(0x87f18b377e625b62c708D5f6EA96EC193558EFD0).owner());
        Loan loanV2 = new Loan();
        Loan _loan = Loan(0x87f18b377e625b62c708D5f6EA96EC193558EFD0);
        _loan.upgradeToAndCall(address(loanV2), new bytes(0));
        // Set AccountStorage to mock to avoid contract call issues
        MockPortfolioFactory mockAccountStorage = new MockPortfolioFactory();
        _loan.setPortfolioFactory(address(mockAccountStorage));
        vm.stopPrank();

        address odosRouterAddress = _loan.odosRouter();
        MockOdosRouterRL mockRouter = new MockOdosRouterRL();
        bytes memory code = address(mockRouter).code;
        vm.allowCheatcodes(odosRouterAddress);
        vm.etch(odosRouterAddress, code);
        MockOdosRouterRL(odosRouterAddress).initMock(address(this));

        // get owner of token
        address user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(_loan), _tokenId);
        _loan.requestLoan(_tokenId, 0, Loan.ZeroBalanceOption.PayToOwner, 0, 0x940181a94A35A4569E4529A3CDfB74e38FD98631, false, false);
        vm.stopPrank();
        (uint256 balance,) = _loan.getLoanDetails(_tokenId);
        assertEq(balance, 0, "should have no balance");

        uint256 beginningLoanAeroBalance = aero.balanceOf(address(_loan));
        uint256 beginningUserUsdcBalance = usdc.balanceOf(address(user));
        uint256 beginningOwnerAeroBalance = aero.balanceOf(address(_loan.owner()));
        // beginning aero balance
        uint256 beginningAeroBalance = aero.balanceOf(address(user));
        address[] memory bribes = new address[](0);
        bytes memory data = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwapMultiOutput.selector,
            address(aero),
            address(aero),
            21919478169541,
            21919478169541,
            address(_loan)
        );
        uint256[2] memory allocations = [uint256(41349), uint256(21919478169541)];
        uint256 rewards = _claimRewards(_loan, _tokenId, bribes, data, allocations);
        uint256 endingLoanAeroBalance = aero.balanceOf(address(_loan));
        assertEq(endingLoanAeroBalance - beginningLoanAeroBalance, 0, "Loan USDC balance should not change");

        uint256 endingUserUsdcBalance = usdc.balanceOf(address(user));
        assertTrue(endingUserUsdcBalance == beginningUserUsdcBalance, "User USDC balance should not increase");
        (balance,) = _loan.getLoanDetails(_tokenId);
        
        uint256 endingAeroBalance = aero.balanceOf(address(user));
        console.log("ending aero balance: ", endingAeroBalance);
        console.log("Balance change: ", endingAeroBalance - beginningAeroBalance);
        assertTrue(endingAeroBalance > beginningAeroBalance, "User Aero balance should increase");
        console.log("Aero balance change: ", endingAeroBalance - beginningAeroBalance);
        uint256 endingOwnerAeroBalance = aero.balanceOf(address(_loan.owner()));
        console.log("ending owner aero balance: ", endingOwnerAeroBalance);
        console.log("Owner Aero balance change: ", endingOwnerAeroBalance - beginningOwnerAeroBalance);
        assertTrue(endingOwnerAeroBalance > beginningOwnerAeroBalance, "Owner Aero balance should increase");
    }

    function testUpgradeLoan() public {
        vm.startPrank(loan.owner());
        Loan loanV2 = new Loan();
        loan.upgradeToAndCall(address(loanV2), new bytes(0));
        vm.stopPrank();
    }


    function xtestReinvestVault() public {
        assertEq(usdc.balanceOf(address(vault)), 100e6, "vault should have 0 balance");
        uint256 _tokenId = 524;

        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));
        uint256 startingVaultBalance = usdc.balanceOf(address(vault));
        
        user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, 0, Loan.ZeroBalanceOption.InvestToVault, 0, address(0), false, false);
        vm.roll(block.number+1);
        vm.stopPrank();
        
        address[] memory bribes = new address[](0);
        // _claimRewards(loan, _tokenId, bribes);

        uint256 endingOwnerBalance = usdc.balanceOf(address(owner));

        

        // owner should not receive rewards
        assertNotEq(endingOwnerBalance - startingOwnerBalance, 0, "owner should receive rewards");
        assertTrue(usdc.balanceOf(address(vault)) > startingVaultBalance, "vault should have more than starting balance");
    }


    function xtestPayToOwner() public {
        assertEq(usdc.balanceOf(address(vault)), 100e6, "vault should have 0 balance");
        uint256 _tokenId = 524;

        
        user = votingEscrow.ownerOf(_tokenId);
        uint256 startingOwnerBalance = usdc.balanceOf(address(Ownable2StepUpgradeable(loan).owner()));
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingLoanBalance = usdc.balanceOf(address(loan));
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, 0, Loan.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);
        vm.roll(block.number+1);
        vm.warp(block.timestamp+1);
        vm.stopPrank();
        

        address[] memory bribes = new address[](0);
        // _claimRewards(loan, _tokenId, bribes);

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

    function xtestPayToOwnerPayoutToken() public {
        assertEq(usdc.balanceOf(address(vault)), 100e6, "vault should have 0 balance");
        uint256 _tokenId = 524;

        
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
        loan.requestLoan(_tokenId, 0, Loan.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);
        vm.roll(block.number+1);
        vm.warp(block.timestamp+1);
        loan.setPreferredToken(_tokenId, address(weth));
        vm.stopPrank();
        

        address[] memory bribes = new address[](0);
        // _claimRewards(loan, _tokenId, bribes);

        uint256 endingUserBalance = weth.balanceOf(address(user));
        uint256 endingOwnerBalance = usdc.balanceOf(address(Ownable2StepUpgradeable(loan).owner()));
        uint256 endingLoanBalance = usdc.balanceOf(address(loan));



        // owner should receive rewards in usdc 
        assertNotEq(endingOwnerBalance - startingOwnerBalance, 0, "owner should receive usd rewards");

        assertNotEq(endingUserBalance - startingUserBalance, 0,  "user should have receive weth rewards");

        assertEq(endingLoanBalance - startingLoanBalance, 0, "loan should not receive rewards");        
    }


    function testMerge() public {
        uint256 _tokenId = 524;
        address _user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(_user);        
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, 0, Loan.ZeroBalanceOption.PayToOwner, 0, address(0), true, false);
        vm.stopPrank();
        
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 7 days);
        
        address _user2 = votingEscrow.ownerOf(66706);
        vm.prank(_user2);
        votingEscrow.transferFrom(_user2, address(_user), 66706);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 7 days);
        vm.startPrank(_user);
        IERC721(address(votingEscrow)).approve(address(loan), 66706);
        loan.merge(66706, 524);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        assertEq(votingEscrow.ownerOf(66706), address(0), "should be burnt");
    }

    function xtestPayoffToken() public {

        usdc.mint(address(vault), 100000e6);

        uint256 _tokenId = 524;

        uint256 loanAmount = 300e6;

        user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, loanAmount, Loan.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);

        vm.stopPrank();

        uint256 _tokenId2 = 7979;
        address user2 = votingEscrow.ownerOf(_tokenId2);
        vm.prank(user2);
        votingEscrow.transferFrom(user2, user, _tokenId2);
        
        vm.startPrank(user);
        vm.warp(block.timestamp+1);
        vm.roll(block.number + 1);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId2);
        loan.requestLoan(_tokenId2, loanAmount, Loan.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);
        loan.setPayoffToken(_tokenId2, true);


        address[] memory bribes = new address[](0);
        // _claimRewards(loan, _tokenId, bribes);


        (uint256 balance,) = loan.getLoanDetails(_tokenId2);
        console.log("balance: %s", balance);
        assertTrue(balance < loanAmount, "Balance should be less than amount");
        (balance,) = loan.getLoanDetails(_tokenId);
        assertEq(balance, 0, "Balance should be 0");
    }

    function xtestPayoffTokenMoreBalance() public {

        usdc.mint(address(vault), 100000e6);

        uint256 _tokenId = 524;

        uint256 loanAmount = 400e6;

        user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, loanAmount, Loan.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);

        vm.stopPrank();

        uint256 _tokenId2 = 7979;
        address user2 = votingEscrow.ownerOf(_tokenId2);
        vm.prank(user2);
        votingEscrow.transferFrom(user2, user, _tokenId2);
        
        vm.startPrank(user);
        vm.warp(block.timestamp+1);
        vm.roll(block.number + 1);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId2);
        loan.requestLoan(_tokenId2, loanAmount, Loan.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);
        loan.setPayoffToken(_tokenId2, true);


        address[] memory bribes = new address[](0);
        // _claimRewards(loan, _tokenId, bribes);


        (uint256 balance,) = loan.getLoanDetails(_tokenId2);
        console.log("balance: %s", balance);
        assertTrue(balance < loanAmount, "Balance should be less than amount");
        (balance,) = loan.getLoanDetails(_tokenId);
        assertNotEq(balance, 0, "Balance should not be 0");
    }

    function xtestIncreaseAmountPercentage() public {
        tokenId = 524;
        user = votingEscrow.ownerOf(tokenId);

        uint256 amount = 1e6;
        
    
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.roll(block.number+1);
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
        uint256 rewards = 0; //// _claimRewards(loan, tokenId, bribes);
        assertEq(rewards, 957174473, "rewards should be 957174473");
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 93053);
    }

    function xtestTopup() public {
        usdc.mint(address(vault), 100000e6);

        uint256 _tokenId = 524;

        uint256 loanAmount = 400e6;

        user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, loanAmount, Loan.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);

        vm.stopPrank();

        uint256 _tokenId2 = 7979;
        address user2 = votingEscrow.ownerOf(_tokenId2);
        vm.prank(user2);
        votingEscrow.transferFrom(user2, user, _tokenId2);
        
        vm.startPrank(user);
        vm.warp(block.timestamp+1);
        vm.roll(block.number + 1);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId2);
        loan.requestLoan(_tokenId2, loanAmount, Loan.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);
        loan.setPayoffToken(_tokenId2, true);
        loan.setTopUp(_tokenId2, true);
        vm.stopPrank();

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        address[] memory bribes = new address[](0);
        // _claimRewards(loan, _tokenId, bribes);
        uint256 endingUserBalance = usdc.balanceOf(address(user));        
        assertTrue(endingUserBalance > startingUserBalance, "User should have more than starting balance");

        (uint256 balance,) = loan.getLoanDetails(_tokenId2);
        assertTrue(balance >  1000e6, "Balance should have increased");
    }


    function xtestTopup2() public {
        usdc.mint(address(vault), 100000e6);

        uint256 _tokenId = 524;

        uint256 loanAmount = 400e6;

        user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, loanAmount, Loan.ZeroBalanceOption.PayToOwner, 0, address(0), false, false);

        vm.stopPrank();

        uint256 _tokenId2 = 7979;
        address user2 = votingEscrow.ownerOf(_tokenId2);
        vm.prank(user2);
        votingEscrow.transferFrom(user2, user, _tokenId2);
        
        vm.startPrank(user);
        vm.warp(block.timestamp+1);
        vm.roll(block.number + 1);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId2);
        loan.requestLoan(_tokenId2, loanAmount, Loan.ZeroBalanceOption.PayToOwner, 0, address(0), true, false);
        loan.setPayoffToken(_tokenId2, true);

        address[] memory bribes = new address[](0);
        // _claimRewards(loan, _tokenId, bribes);


        (uint256 balance,) = loan.getLoanDetails(_tokenId2);
        assertTrue(balance >  1000e6, "Balance should have increased");
    }


    // function testManualVoting() public {
    //     uint256 _tokenId = 524;
    //     usdc.mint(address(vault), 10000e6);
    //     uint256 amount = 1e6;
    //     address _user = votingEscrow.ownerOf(_tokenId);
    //     uint256 lastVoteTimestamp = voter.lastVoted(_tokenId);
    //     console.log("last vote timestamp: %s", lastVoteTimestamp);
        
    //     address[] memory manualPools = new address[](1);
    //     manualPools[0] = address(0xC200F21EfE67c7F41B81A854c26F9cdA80593065);
    //     uint256[] memory manualWeights = new uint256[](1);
    //     manualWeights[0] = 100e18;

    //     console.log(address(loan));
    //     vm.startPrank(IOwnable(address(loan)).owner());
    //     loan.setApprovedPools(manualPools, true);
    //     vm.stopPrank();

    //     uint256[] memory tokenIds = new uint256[](1);
    //     tokenIds[0] = _tokenId;
        
    //     vm.startPrank(_user);
    //     IERC721(address(votingEscrow)).approve(address(loan), _tokenId);

    //     uint256 blockTimestamp = ProtocolTimeLibrary.epochStart(block.timestamp);
    //     vm.roll(block.number + 1);
    //     vm.warp(ProtocolTimeLibrary.epochStart(blockTimestamp) + 2 hours);
    //     loan.requestLoan(_tokenId, amount, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
    //     vm.warp(block.timestamp + 2);
    //     vm.roll(block.number + 2);
    //     loan.userVote(tokenIds, manualPools, manualWeights);
    //     lastVoteTimestamp = block.timestamp;
    //     assertEq(lastVoteTimestamp, voter.lastVoted(_tokenId));
    //     vm.roll(block.number + 1);
    //     vm.warp(block.timestamp + 1);
    //     vm.warp(ProtocolTimeLibrary.epochStart(blockTimestamp) + 7 days + 1);
    //     loan.vote(_tokenId); // does not vote because of manual voting
    //     assertNotEq(block.timestamp, voter.lastVoted(_tokenId), "1");
    //     vm.roll(block.number + 1);
    //     vm.warp(block.timestamp + 1);
    //     loan.vote(_tokenId); // does not vote because of manual voting
    //     assertNotEq(block.timestamp, voter.lastVoted(_tokenId), "2");
    //     vm.warp(ProtocolTimeLibrary.epochStart(blockTimestamp) + 12 days + 22 hours);
    //     loan.vote(_tokenId); // does not vote because of manual voting
    //     assertNotEq(block.timestamp, voter.lastVoted(_tokenId), "4");

    //     vm.warp(ProtocolTimeLibrary.epochStart(blockTimestamp) + 14 days + 22 hours);
    //     vm.roll(block.number + 1);
    //     loan.vote(_tokenId); // should not success, not within voting winow
    //     assertNotEq(block.timestamp, voter.lastVoted(_tokenId), "5");
        
    //     vm.roll(block.number + 1);
    //     vm.warp(ProtocolTimeLibrary.epochStart(blockTimestamp) + 20 days + 23 hours + 4);
    //     loan.vote(_tokenId); // should succees
    //     vm.roll(block.number);
    //     vm.warp(block.timestamp);
    //     assertEq(block.timestamp, voter.lastVoted(_tokenId), "6");

    //     assertNotEq(voter.poolVote(_tokenId, 0), manualPools[0]);
    //     vm.stopPrank();

    //     vm.startPrank(Ownable2StepUpgradeable(loan).owner());
    //     address[] memory pools = new address[](1);
    //     pools[0] = address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59);
    //     uint256[] memory weights = new uint256[](1);
    //     weights[0] = 100e18;
    //     loan.setApprovedPools(pools, true);
    //     loan.setDefaultPools(pools, weights);
    //     vm.stopPrank();

    //     uint256 loanWeight = loan.getTotalWeight();
    //     assertTrue(loanWeight > 0, "loan weight should be greater than 0");
    // }

    // ============ ADDITIONAL COMPREHENSIVE TESTS ============

    /// @notice Test requesting loan with token you don't own should fail
    function testRequestLoanNotOwner() public {
        // Try to request loan with a token we don't own
        vm.startPrank(owner);
        vm.expectRevert();
        loan.requestLoan(tokenId, 1e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();
    }

    /// @notice Test increasing loan beyond max allowed fails
    function testIncreaseLoanBeyondMax() public {
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 0, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();

        (uint256 maxLoan,) = loan.getMaxLoan(tokenId);

        vm.startPrank(user);
        vm.expectRevert();
        loan.increaseLoan(tokenId, maxLoan + 1e6);
        vm.stopPrank();
    }

    /// @notice Test increasing loan with non-borrower fails
    function testIncreaseLoanNotBorrower() public {
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 1e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert();
        loan.increaseLoan(tokenId, 1e6);
        vm.stopPrank();
    }

    /// @notice Test partial payment reduces loan balance correctly
    function testPartialPayment() public {
        usdc.mint(address(user), 100e6);

        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 10e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

        (uint256 balanceBefore,) = loan.getLoanDetails(tokenId);
        assertTrue(balanceBefore > 10e6, "Balance should include origination fee");

        usdc.approve(address(loan), 5e6);
        loan.pay(tokenId, 5e6);

        (uint256 balanceAfter,) = loan.getLoanDetails(tokenId);
        assertTrue(balanceAfter < balanceBefore, "Balance should decrease after payment");
        assertTrue(balanceAfter > 0, "Balance should not be zero after partial payment");
        vm.stopPrank();
    }

    /// @notice Test claiming collateral with active loan fails
    function testClaimCollateralWithActiveLoan() public {
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 1e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

        vm.expectRevert();
        loan.claimCollateral(tokenId);
        vm.stopPrank();
    }

    /// @notice Test claiming collateral as non-borrower fails
    function testClaimCollateralNotBorrower() public {
        usdc.mint(address(user), 100e6);

        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 1e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

        // Pay off the loan fully
        usdc.approve(address(loan), 10e6);
        loan.pay(tokenId, 0); // Pay full balance
        vm.stopPrank();

        // Try to claim as non-borrower
        vm.startPrank(owner);
        vm.expectRevert();
        loan.claimCollateral(tokenId);
        vm.stopPrank();
    }

    /// @notice Test setting zero balance option
    function testSetZeroBalanceOption() public {
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 1e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

        loan.setZeroBalanceOption(tokenId, Loan.ZeroBalanceOption.PayToOwner);
        vm.stopPrank();
    }

    /// @notice Test setting zero balance option as non-borrower fails
    function testSetZeroBalanceOptionNotBorrower() public {
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 1e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert();
        loan.setZeroBalanceOption(tokenId, Loan.ZeroBalanceOption.PayToOwner);
        vm.stopPrank();
    }

    /// @notice Test setting increase percentage
    function testSetIncreasePercentage() public {
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 1e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

        loan.setIncreasePercentage(tokenId, 5000); // 50%
        vm.stopPrank();
    }

    /// @notice Test setting increase percentage above 100% fails
    function testSetIncreasePercentageAboveMax() public {
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 1e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

        vm.expectRevert();
        loan.setIncreasePercentage(tokenId, 10001); // > 100%
        vm.stopPrank();
    }

    /// @notice Test setting increase percentage as non-borrower fails
    function testSetIncreasePercentageNotBorrower() public {
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 1e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert();
        loan.setIncreasePercentage(tokenId, 5000);
        vm.stopPrank();
    }

    /// @notice Test setting top-up option
    function testSetTopUp() public {
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 1e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

        loan.setTopUp(tokenId, true);
        vm.stopPrank();
    }

    /// @notice Test setting top-up option as non-borrower fails
    function testSetTopUpNotBorrower() public {
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 1e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert();
        loan.setTopUp(tokenId, true);
        vm.stopPrank();
    }

    /// @notice Test requesting loan with invalid increase percentage fails
    function testRequestLoanInvalidIncreasePercentage() public {
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        vm.expectRevert();
        loan.requestLoan(tokenId, 1e6, Loan.ZeroBalanceOption.DoNothing, 10001, address(0), false, false);
        vm.stopPrank();
    }

    /// @notice Test requesting loan with unapproved preferred token fails
    function testRequestLoanUnapprovedPreferredToken() public {
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        vm.expectRevert();
        loan.requestLoan(tokenId, 1e6, Loan.ZeroBalanceOption.PayToOwner, 0, address(0xdead), false, false);
        vm.stopPrank();
    }

    /// @notice Test increase amount by non-owner fails
    function testIncreaseAmountNotOwner() public {
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 0, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();

        deal(address(aero), owner, 100e18);

        vm.startPrank(owner);
        aero.approve(address(loan), 100e18);
        // This should succeed - anyone can increase the lock amount
        loan.increaseAmount(tokenId, 10e18);
        vm.stopPrank();
    }

    /// @notice Test payMultiple pays off multiple loans
    function testPayMultiple() public {
        uint256 _fork;
        _fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(_fork);
        vm.rollFork(31911971);

        vm.startPrank(Loan(0x87f18b377e625b62c708D5f6EA96EC193558EFD0).owner());
        Loan loanV2 = new Loan();
        Loan _loan = Loan(0x87f18b377e625b62c708D5f6EA96EC193558EFD0);
        _loan.upgradeToAndCall(address(loanV2), new bytes(0));
        MockPortfolioFactory mockAccountStorage = new MockPortfolioFactory();
        _loan.setPortfolioFactory(address(mockAccountStorage));
        vm.stopPrank();

        address _user = vm.addr(0x1234);

        // Give user some AERO to create locks
        deal(address(aero), _user, 10000e18);

        // Mint USDC to vault
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(_loan._vault(), 1000e6);
        usdc.mint(_user, 100e6);

        // Create two locks
        vm.startPrank(_user);
        aero.approve(address(votingEscrow), type(uint256).max);
        uint256 token1 = votingEscrow.createLock(1000e18, 4 * 365 days);
        vm.roll(block.number + 1);
        uint256 token2 = votingEscrow.createLock(1000e18, 4 * 365 days);
        vm.roll(block.number + 1);

        // Request loans for both
        IERC721(address(votingEscrow)).approve(address(_loan), token1);
        _loan.requestLoan(token1, 1e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

        IERC721(address(votingEscrow)).approve(address(_loan), token2);
        _loan.requestLoan(token2, 1e6, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

        (uint256 balance1Before,) = _loan.getLoanDetails(token1);
        (uint256 balance2Before,) = _loan.getLoanDetails(token2);
        assertTrue(balance1Before > 0, "Token1 should have balance");
        assertTrue(balance2Before > 0, "Token2 should have balance");

        // Pay off both loans
        usdc.approve(address(_loan), 50e6);
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = token1;
        tokenIds[1] = token2;
        _loan.payMultiple(tokenIds);

        (uint256 balance1After,) = _loan.getLoanDetails(token1);
        (uint256 balance2After,) = _loan.getLoanDetails(token2);
        assertEq(balance1After, 0, "Token1 should be paid off");
        assertEq(balance2After, 0, "Token2 should be paid off");
        vm.stopPrank();
    }

    /// @notice Test that only owner can set multiplier
    function testSetMultiplierOnlyOwner() public {
        vm.prank(owner);
        loan.setMultiplier(50);

        vm.prank(user);
        vm.expectRevert();
        loan.setMultiplier(100);
    }

    /// @notice Test that only owner can set approved pools
    function testSetApprovedPoolsOnlyOwner() public {
        address[] memory pools = new address[](1);
        pools[0] = address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59);

        vm.prank(owner);
        loan.setApprovedPools(pools, true);

        vm.prank(user);
        vm.expectRevert();
        loan.setApprovedPools(pools, true);
    }

    /// @notice Test renounce ownership is disabled
    function testRenounceOwnershipDisabled() public {
        vm.prank(owner);
        vm.expectRevert();
        loan.renounceOwnership();
    }

    /// @notice Test rescue ERC20 tokens
    function testRescueERC20() public {
        // Send some tokens to loan contract directly
        usdc.mint(address(loan), 10e6);

        uint256 ownerBalanceBefore = usdc.balanceOf(owner);

        vm.prank(owner);
        loan.rescueERC20(address(usdc), 10e6);

        uint256 ownerBalanceAfter = usdc.balanceOf(owner);
        assertEq(ownerBalanceAfter - ownerBalanceBefore, 10e6, "Owner should receive rescued tokens");
    }

    /// @notice Test rescue ERC20 only owner
    function testRescueERC20OnlyOwner() public {
        usdc.mint(address(loan), 10e6);

        vm.prank(user);
        vm.expectRevert();
        loan.rescueERC20(address(usdc), 10e6);
    }

    /// @notice Test incentivize vault
    function testIncentivizeVault() public {
        usdc.mint(address(user), 100e6);

        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));

        vm.startPrank(user);
        usdc.approve(address(loan), 50e6);
        loan.incentivizeVault(50e6);
        vm.stopPrank();

        uint256 vaultBalanceAfter = usdc.balanceOf(address(vault));
        assertEq(vaultBalanceAfter - vaultBalanceBefore, 50e6, "Vault should receive incentive");
    }

    /// @notice Test setting payoff token requires balance
    function testSetPayoffTokenRequiresBalance() public {
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 0, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

        // Should fail because loan balance is 0
        vm.expectRevert();
        loan.setPayoffToken(tokenId, true);
        vm.stopPrank();
    }

    /// @notice Test loan origination fee is applied correctly
    function testOriginationFee() public {
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        uint256 loanAmount = 10e6;
        loan.requestLoan(tokenId, loanAmount, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

        (uint256 balance,) = loan.getLoanDetails(tokenId);
        // Origination fee is 0.8% (80/10000)
        uint256 expectedFee = (loanAmount * 80) / 10000;
        assertEq(balance, loanAmount + expectedFee, "Balance should include origination fee");
        vm.stopPrank();
    }

    /// @notice Test active assets tracking
    function testActiveAssetsTracking() public {
        assertEq(loan.activeAssets(), 0, "Should start with 0 active assets");

        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        uint256 loanAmount = 5e6;
        loan.requestLoan(tokenId, loanAmount, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);
        vm.stopPrank();

        assertEq(loan.activeAssets(), loanAmount, "Active assets should equal loan amount");

        // Pay off loan
        usdc.mint(address(user), 10e6);
        vm.startPrank(user);
        usdc.approve(address(loan), 10e6);
        loan.pay(tokenId, 0);
        vm.stopPrank();

        assertEq(loan.activeAssets(), 0, "Active assets should be 0 after payoff");
    }

    /// @notice Test loan with top-up option automatically maxes loan
    function testLoanWithTopUpOption() public {
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        // Request loan with topUp=true and amount=0
        loan.requestLoan(tokenId, 0, Loan.ZeroBalanceOption.DoNothing, 0, address(0), true, false);

        (uint256 balance,) = loan.getLoanDetails(tokenId);
        assertTrue(balance > 0, "Loan should have balance due to top-up");
        vm.stopPrank();
    }

    /// @notice Test increase loan below minimum amount fails
    function testIncreaseLoanBelowMinimum() public {
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, 0, Loan.ZeroBalanceOption.DoNothing, 0, address(0), false, false);

        // Try to increase by less than .01 USDC
        vm.expectRevert();
        loan.increaseLoan(tokenId, 0.001e6);
        vm.stopPrank();
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
        bytes memory data = "";
        vm.prank(0x40AC2E93d1257196a418fcE7D6eDAcDE65aAf2BA);
        return _loan.claim(_tokenId, fees, tokens, tradeData, allocations);
    }
}
