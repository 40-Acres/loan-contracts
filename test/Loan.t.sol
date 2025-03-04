// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/Loan.sol";
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
import {BaseDeploy} from "../script/BaseDeploy.s.sol";
import {BaseUpgrade} from "../script/BaseUpgrade.s.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
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
    }

    // FOR ON FRIDAY DONT APPROVE
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
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing);


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



    
    function testIncreseLoanMaxLoan() public {
        vm.startPrank(owner);
        loan.setMultiplier(8);
        vm.stopPrank();
        (uint256 maxLoan,  ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 90538);
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
        vm.expectRevert("Cannot increase loan beyond max loan amount");
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing);

        amount = 1e6;
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > 1e6);
        assertTrue(usdc.balanceOf(address(vault)) < 100e6);

        (uint256 balance, address borrower,) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount);
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
    }


    function testLoanVotingAdvance() public {
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
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > startingUserBalance, "User should have more than starting balance");
        assertEq(usdc.balanceOf(address(vault)), 99e6, "Vault should have 1e6");
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "Owner should have starting balance");


        (uint256 balance, address borrower,) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount, "Balance should be more than amount");
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
        assertEq(loan.activeAssets(), amount, "should have 0 active assets");

        loan.claimRewards(tokenId);
        assertTrue(usdc.balanceOf(address(vault)) > 99e6, "Vault should have .more than original balance");
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 37055346);
    }

    function testIncreaseLoan() public {
        uint256 amount = 1e6;

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "ff");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > 1e6, "User should have more than loan");

        assertEq(loan.activeAssets(),1e6, "ff");
        (uint256 balance, address borrower, address[] memory pools) = loan.getLoanDetails(tokenId);
        assertEq(pools.length, 1, "should have 1 pool");
        assertEq(pools[0], pool[0], "should be in pool");
        assertTrue(balance > amount, "Balance should be 1e6");
        assertEq(borrower, user);

        vm.startPrank(user);
        loan.increaseLoan(tokenId, amount);
        vm.stopPrank();

        (balance, borrower, ) = loan.getLoanDetails(tokenId);
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
        loan.requestLoan(tokenId, amount, Loan.ZeroBalanceOption.DoNothing);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(user)), 1e6+startingUserBalance, "User should have 1e6");
        assertEq(usdc.balanceOf(address(vault)), 99e6, "Loan should have 97e6");

        assertEq(votingEscrow.ownerOf(tokenId), address(loan));

        vm.startPrank(user);
        usdc.approve(address(loan), 5e6);
        loan.pay(tokenId, 0);
        loan.claimCollateral(tokenId);
        vm.stopPrank();

        assertEq(loan.lastEpochReward(), .008e6, "should have .8% of rewards");
        assertEq(votingEscrow.ownerOf(tokenId), address(user));
        console.log(usdc.balanceOf(address(vault)));
        assertTrue(usdc.balanceOf(address(vault)) > 100e6, "Vault should have more than initial balance");


    }


    function testUpgradeLoan() public {
        vm.startPrank(loan.owner());
        Loan loanV2 = new Loan();
        loan.upgradeToAndCall(address(loanV2), new bytes(0));
        vm.stopPrank();
    }


    function testReinvestVault() public {
        assertEq(usdc.balanceOf(address(vault)), 100e6, "vault should have 0 balance");
        uint256 _tokenId = 6687;

        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));
        
        user = votingEscrow.ownerOf(_tokenId);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, 0, Loan.ZeroBalanceOption.InvestToVault);
        vm.stopPrank();
        
        loan.claimRewards(_tokenId);
        loan.claimBribes(_tokenId, pool);

        uint256 endingOwnerBalance = usdc.balanceOf(address(owner));

        

        // owner should not receive rewards
        assertEq(endingOwnerBalance - startingOwnerBalance, 0, "owner should not receive rewards");
    
    }


    function testPayToOwner() public {
        assertEq(usdc.balanceOf(address(vault)), 100e6, "vault should have 0 balance");
        uint256 _tokenId = 6687;

        
        user = votingEscrow.ownerOf(_tokenId);
        uint256 startingOwnerBalance = usdc.balanceOf(address(Ownable2StepUpgradeable(loan).owner()));
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingLoanBalance = usdc.balanceOf(address(loan));
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, 0, Loan.ZeroBalanceOption.PayToOwner);
        vm.stopPrank();
        
        loan.claimRewards(_tokenId);

        uint256 endingUserBalance = usdc.balanceOf(address(user));
        uint256 endingOwnerBalance = usdc.balanceOf(address(Ownable2StepUpgradeable(loan).owner()));
        uint256 endingLoanBalance = usdc.balanceOf(address(loan));

        uint256 totalRewards = endingUserBalance - startingUserBalance + endingOwnerBalance - startingOwnerBalance;


        // owner should receive rewards 1% f rewards
        uint256 protocolFee = totalRewards / 100;
        uint256 paidToUser = totalRewards - protocolFee;        
        assertEq(endingUserBalance - startingUserBalance, paidToUser,  "user should receive rewards");
        assertEq(endingOwnerBalance - startingOwnerBalance, protocolFee, "owner should receive rewards");
        assertEq(endingLoanBalance - startingLoanBalance, 0, "loan should not receive rewards");        
    }

        
    function testDefaultPools() public { 
        address _pool = loan._defaultPools(0);
        assertTrue(_pool != address(0), "default pool should not be 0");

        assertTrue(loan._defaultWeights(0) > 0, "default pool weight should be greater than 0");
        
        uint256 defaultPoolChangeTime = loan._defaultPoolChangeTime();
        assertTrue(defaultPoolChangeTime > 0, "default pool change time should be greater than 0");

        vm.startPrank(Ownable2StepUpgradeable(loan).owner());
        address[] memory pools = new address[](2);
        pools[0] = address(0x52f38A65DAb3Cf23478cc567110BEC90162aB832);
        pools[1] = address(0x52F38a65daB3cF23478Cc567110bEc90162AB833);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 50e18;
        weights[1] = 50e18;
        loan.setDefaultPools(pools, weights);
        vm.stopPrank();

        assertTrue(loan._defaultPools(0) == pools[0], "default pool should be updated");
        assertTrue(loan._defaultPools(1) == pools[1], "default pool should be updated");
        assertTrue(loan._defaultWeights(0) == weights[0], "default pool weight should be updated");
        assertTrue(loan._defaultWeights(1) == weights[1], "default pool weight should be updated");
        assertTrue(loan._defaultPoolChangeTime() >= defaultPoolChangeTime, "default pool change time should be updated");
    }
}
