// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/Loan.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotingEscrow } from "../src/interfaces/IVotingEscrow.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { RateCalculator } from "src/RateCalculator.sol";
import { ProtocolTimeLibrary } from "src/libraries/ProtocolTimeLibrary.sol";

interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(address minter, uint256 minterAllowedAmount) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);

}

contract LoanTest is Test {
    uint256 fork;

    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    address[] pool = [address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59)];

    // deployed contracts
    Vault vault;
    Loan public loan;
    RateCalculator rateCalculator;
    address owner;
    address user;
    uint256 version;
    uint256 tokenId = 64196;

    function setUp() public {
        fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(24353746);
        version = 0;
        owner = vm.addr(0x123);
        user = votingEscrow.ownerOf(tokenId);

        loan = new Loan();
        vault = new Vault(address(usdc), address(loan));
        rateCalculator = new RateCalculator(address(loan));
        loan.setVault(address(vault));
        loan.setRateCalculator(address(rateCalculator));
        loan.setMultiplier(100000000000);
        loan.transferOwnership(owner);
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


    function testGetMaxLoan() public view {
        (uint256 maxLoan,  ) = loan.getMaxLoan(tokenId);
        assertTrue(maxLoan / 1e6 > 10);
        console.log("maxLoan", maxLoan);
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
        loan.requestLoan(tokenId, amount, pool);

        amount = .01e6;
        loan.requestLoan(tokenId, amount, pool);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > .01e6);
        assertTrue(usdc.balanceOf(address(vault)) < 100e6);

        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount);
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
    }


    function testLoanVotingAdvance() public {
        tokenId = 524;
        user = votingEscrow.ownerOf(tokenId);

        uint256 amount = .01e6;
        
        
    
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, pool);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > startingUserBalance, "User should have more than starting balance");
        assertEq(usdc.balanceOf(address(vault)), 99.99e6, "Vault should have .01e6");
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "Owner should have starting balance");


        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount, "Balance should be more than amount");
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
        assertEq(loan.activeAssets(), amount, "should have 0 active assets");

        loan.claimRewards(tokenId);
        assertTrue(usdc.balanceOf(address(vault)) > 99.99e6, "Vault should have .more than original balance");
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 37051653);
    }

    function testIncreaseLoan() public {
        uint256 amount = .01e6;

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "ff");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, pool);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > .01e6, "User should have more than loan");

        assertEq(loan.activeAssets(),.01e6, "ff");
        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount, "Balance should be .01e6");
        assertEq(borrower, user);

        vm.startPrank(user);
        loan.increaseLoan(tokenId, amount);
        vm.stopPrank();

        (balance, borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance> amount, "Balance should be more than amount");
        assertEq(borrower, user);
        assertEq(loan.activeAssets(),0.02e6, "ff");

        assertEq(usdc.balanceOf(address(user)), 0.02e6 + startingUserBalance, "User should have .02e6");
        assertEq(usdc.balanceOf(address(vault)), 99.98e6, "Loan should have .01e6");
        
    }



    function testLoanFullPayoff() public {
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(user), 100e6);
        vm.stopPrank();

        uint256 amount = .01e6;

        assertEq(votingEscrow.ownerOf(tokenId), address(user), "User should own token");

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance, "User should have startingUserBalance");
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount, pool);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(user)), .01e6+startingUserBalance, "User should have .01e6");
        assertEq(usdc.balanceOf(address(vault)), 99.99e6, "Loan should have 97e6");

        assertEq(votingEscrow.ownerOf(tokenId), address(loan));

        vm.startPrank(user);
        usdc.approve(address(loan), 1e6);
        loan.pay(tokenId, 0);
        loan.claimCollateral(tokenId);
        vm.stopPrank();

        assertEq(votingEscrow.ownerOf(tokenId), address(user));
        assertTrue(usdc.balanceOf(address(vault)) > 100e6, "Loan should have more than initial balance");

        rateCalculator.setInterestRate(100, 100);
    }


}


contract LoanEpochFlipTest is Test {
    uint256 fork;

    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    address[] pool = [address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59)];

    // deployed contracts
    Vault vault;
    Loan public loan;
    RateCalculator rateCalculator;
    address owner;
    address user;
    uint256 version;
    uint256 tokenId = 64196;

    uint256 preEpochBlock = 24353745;
    uint256 epochHoldBlock = 25099789;
    uint256 epochVotingBlock = 25099989;

    function setUp() public {
        fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(epochVotingBlock);
        version = 0;
        owner = vm.addr(0x123);
        user = votingEscrow.ownerOf(tokenId);

        loan = new Loan();
        vault = new Vault(address(usdc), address(loan));
        rateCalculator = new RateCalculator(address(loan));
        loan.setVault(address(vault));
        loan.setRateCalculator(address(rateCalculator));
        loan.setMultiplier(100000000000);
        loan.transferOwnership(owner);
        // allow this test contract to mint USDC
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(voter), 100e6);
        usdc.mint(address(vault), 100e6);
        vm.stopPrank();
    }



    function testLoanVotingAdvance() public {
        uint256 _tokenId = 64279;
        user = votingEscrow.ownerOf(_tokenId);

        uint256 amount = .01e6;
    
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, amount, pool);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > startingUserBalance, "User should have more than starting balance");
        assertEq(usdc.balanceOf(address(vault)), 99.99e6, "Vault should have .01e6");
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "Owner should have starting balance");


        (uint256 balance, address borrower) = loan.getLoanDetails(_tokenId);
        assertTrue(balance > amount, "Balance should be more than amount");
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(_tokenId), address(loan));
        assertEq(loan.activeAssets(), amount, "should have 0 active assets");

        loan.claimRewards(_tokenId);
        assertTrue(usdc.balanceOf(address(vault)) > 99.99e6, "Vault should have .more than original balance");
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 251223);
    }


    function testPayToOwner() public {
        uint256 _tokenId = 64279;
        user = votingEscrow.ownerOf(_tokenId);

        uint256 amount = .01e6;
    
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, amount, pool);
        loan.setZeroBalanceOption(_tokenId, Loan.ZeroBalanceOption.PayToOwner);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > startingUserBalance, "User should have more than starting balance");
        assertEq(usdc.balanceOf(address(vault)), 99.99e6, "Vault should have .01e6");
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "Owner should have starting balance");


        (uint256 balance, address borrower) = loan.getLoanDetails(_tokenId);
        assertTrue(balance > amount, "Balance should be more than amount");
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(_tokenId), address(loan));
        assertEq(loan.activeAssets(), amount, "should have 0 active assets");

        uint256 preBalance = usdc.balanceOf(address(user));
        loan.claimRewards(_tokenId);
        uint256 postBalance = usdc.balanceOf(address(user));
        assertTrue(usdc.balanceOf(address(vault)) > 99.99e6, "Vault should have .more than original balance");
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 251223);
        assertEq(votingEscrow.ownerOf(_tokenId), address(loan));
        assertTrue(postBalance > preBalance, "User should have more than preBalance");
    }

    function testReturnNft() public {
        uint256 _tokenId = 64279;
        user = votingEscrow.ownerOf(_tokenId);

        uint256 amount = .01e6;
    
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(loan)), 0, "Loan should start have 0 balance");
        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, amount, pool);
        loan.setZeroBalanceOption(_tokenId, Loan.ZeroBalanceOption.ReturnNft);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > startingUserBalance, "User should have more than starting balance");
        assertEq(usdc.balanceOf(address(vault)), 99.99e6, "Vault should have .01e6");
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "Owner should have starting balance");


        (uint256 balance, address borrower) = loan.getLoanDetails(_tokenId);
        assertTrue(balance > amount, "Balance should be more than amount");
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(_tokenId), address(loan));
        assertEq(loan.activeAssets(), amount, "should have 0 active assets");

        loan.claimRewards(_tokenId);
        assertTrue(usdc.balanceOf(address(vault)) > 99.99e6, "Vault should have .more than original balance");
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");
    

        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 251223);
        assertEq(usdc.balanceOf(address(loan)), 0, "Loan should have 0 balance");

        assertEq(votingEscrow.ownerOf(_tokenId), user);
    }

    function testPayToVault() public {
        uint256 _tokenId = 64279;
        user = votingEscrow.ownerOf(_tokenId);

        uint256 amount = .01e6;
    
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, amount, pool);
        loan.setZeroBalanceOption(_tokenId, Loan.ZeroBalanceOption.InvestToVault);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > startingUserBalance, "User should have more than starting balance");
        assertEq(usdc.balanceOf(address(vault)), 99.99e6, "Vault should have .01e6");
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "Owner should have starting balance");


        (uint256 balance, address borrower) = loan.getLoanDetails(_tokenId);
        assertTrue(balance > amount, "Balance should be more than amount");
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(_tokenId), address(loan));
        assertEq(loan.activeAssets(), amount, "should have 0 active assets");

        uint256 preBalance = usdc.balanceOf(address(vault));
        loan.claimRewards(_tokenId);
        uint256 postBalance = usdc.balanceOf(address(vault));
        assertTrue(usdc.balanceOf(address(vault)) > 99.99e6, "Vault should have .more than original balance");
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch > 0, "rewardsPerEpoch should be greater than 0");

        assertEq(vault.epochRewardsLocked(), 251223);
        assertEq(votingEscrow.ownerOf(_tokenId), address(loan));
        assertTrue(postBalance > preBalance, "Vault should have more than preBalance");
    }

    function testReinvest() public {
        uint256 _tokenId = 64279;
        user = votingEscrow.ownerOf(_tokenId);

        uint256 amount = .01e6;
    
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), _tokenId);
        loan.requestLoan(_tokenId, amount, pool);
        loan.setZeroBalanceOption(_tokenId, Loan.ZeroBalanceOption.ReinvestVeNft);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > startingUserBalance, "User should have more than starting balance");
        assertEq(usdc.balanceOf(address(vault)), 99.99e6, "Vault should have .01e6");
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "Owner should have starting balance");


        (uint256 balance, address borrower) = loan.getLoanDetails(_tokenId);
        assertTrue(balance > amount, "Balance should be more than amount");
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(_tokenId), address(loan));
        assertEq(loan.activeAssets(), amount, "should have 0 active assets");

        int128 preBalance = votingEscrow.locked(_tokenId).amount;
        usdc.approve(address(loan), 10008);
        loan.pay(_tokenId, 10008);

        ( balance,  borrower) = loan.getLoanDetails(_tokenId);
        assertEq(balance , 0, "Balance should be 0");
        loan.claimRewards(_tokenId);
        int128 postBalance = votingEscrow.locked(_tokenId).amount;
        assertTrue(usdc.balanceOf(address(vault)) > 99.99e6, "Vault should have .more than original balance");
        // assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");


        uint256 rewardsPerEpoch = loan._rewardsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp));
        assertTrue(rewardsPerEpoch ==  0, "rewardsPerEpoch should be greater than 0");

        assertEq(votingEscrow.ownerOf(_tokenId), address(loan));
        console.log("pre", postBalance);
        console.log("post", postBalance);
        assertTrue(postBalance > preBalance, "Vault should have more than preBalance");

    
    }
}
