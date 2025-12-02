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
import { IMinter } from "src/interfaces/IMinter.sol";

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



    
    function git () public {
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


    function testClaim() public {
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
        bytes memory data = hex"84a7f3dd020100016877B1b0c6267E0AD9aa4C0df18A547AA2f6B08d073a9f858ec468c400020704077c61afebec0001df033790907c60c9B81aE355F76F74f52F92114A00016e2c81b6c2c0e02360f00a0da694e489acb0b05e090764453ee13b356a3700000004043b927079000187f18b377e625b62c708D5f6EA96EC193558EFD0000000000401030500340201000102018000001702080201030401ff000000000000000000df033790907c60c9b81ae355f76f74f52f92114a420000000000000000000000000000000000000651c230951b82dbf7b8696b6fcd2be199cc10779f6e2c81b6c2c0e02360f00a0da694e489acb0b05e00000000000000000000000000000000";
        uint256[2] memory allocations = [uint256(41349), uint256(21919478169541)];
        uint256 rewards = _claimRewards(_loan, _tokenId, bribes, data, allocations);
        uint256 endingLoanUsdcBalance = usdc.balanceOf(address(_loan));
        assertEq(endingLoanUsdcBalance - beginningLoanUsdcBalance, 0, "Loan USDC balance should not change");

        uint256 endingUserUsdcBalance = usdc.balanceOf(address(user));
        assertTrue(endingUserUsdcBalance > beginningUserUsdcBalance, "User USDC balance should increase");
        (balance,) = _loan.getLoanDetails(_tokenId);
        // balance should be lower
        // assertEq(balance, 5006370);
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
        bytes memory data = hex"84a7f3dd020100016877B1b0c6267E0AD9aa4C0df18A547AA2f6B08d0c38863732cb22bc000000000000020704077c61afebec000000016e2c81b6c2c0e02360f00a0da694e489acb0b05e090764453ee13b356a370000001c042e9517a8000187f18b377e625b62c708D5f6EA96EC193558EFD00000000005010307000002020800000102010408010103040100080101050601ff0000000051c230951b82dbf7b8696b6fcd2be199cc10779f6e2c81b6c2c0e02360f00a0da694e489acb0b05e20cb8f872ae894f7c9e32e621c186e5afce82fd04200000000000000000000000000000000000006e5b5f522e98b5a2baae212d4da66b865b781db97833589fcd6edb6e08f4c7c32d4f71b54bda029130000000000000000";
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
        loan.setLoanOptions(_tokenId, Loan.ZeroBalanceOption.PayToOwner, false, address(weth));
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
        loan.setLoanOptions(_tokenId2, Loan.ZeroBalanceOption.PayToOwner, true, address(0));
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
