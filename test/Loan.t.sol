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

interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(address minter, uint256 minterAllowedAmount) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);

}

contract LoanTest is Test {
    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    address pool = address(0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d);

    // deployed contracts
    Vault vault;
    Loan public loan;
    RateCalculator rateCalculator;
    address owner;
    address user;
    uint256 version;
    uint256 tokenId = 64196;

    function setUp() public {
        version = 0;

        owner = vm.addr(0x123);
        user = votingEscrow.ownerOf(tokenId);

        loan = new Loan();
        vault = new Vault(address(usdc), address(loan));
        rateCalculator = new RateCalculator(address(loan));
        loan.setVault(address(vault));
        loan.setRateCalculator(address(rateCalculator));
        loan.transferOwnership(owner);
        // allow this test contract to mint USDC
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(voter), 100e18);
        usdc.mint(address(vault), 100e18);
        vm.stopPrank();
    }

    // FOR ON FRIDAY DONT APPROVE
    function testOwner() public view {
        address o = loan.owner();
        assertEq(o, owner);
    }


    function testGetMaxLoan() public {
        assertTrue(loan.getMaxLoan(tokenId) / 1e18 < 1);
    }

    function testNftOwner() public {
        assertEq(votingEscrow.ownerOf(tokenId), address(user));
    }

    function testLoanRequest() public {
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e18);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        uint256 amount = 5e18;
        vm.expectRevert("Cannot increase loan beyond max loan amount");
        loan.requestLoan(tokenId, amount);

        amount = .01e18;
        loan.requestLoan(tokenId, amount);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > .01e18);
        assertTrue(usdc.balanceOf(address(vault)) < 100e18);

        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount);
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
    }


    function testLoanVotingAdvance() public {
        // tokenId = 8223;
        // tokenId = 16223; expired
        // tokenId = 60151;
        tokenId = 524;
        user = votingEscrow.ownerOf(tokenId);

        uint256 amount = .01e18;
        uint256 expiration = block.timestamp + 1000;
        uint256 endTimestamp = block.timestamp + 1000;
    
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        uint256 startingOwnerBalance = usdc.balanceOf(address(owner));

        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e18);
        assertEq(loan.activeAssets(),0, "should have 0 active assets");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > startingUserBalance, "User should have more than starting balance");
        assertEq(usdc.balanceOf(address(vault)), 99.99e18, "Vault should have .01e18");
        assertEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "Owner should have starting balance");


        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount, "Balance should be more than amount");
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
        assertEq(loan.activeAssets(), amount, "should have 0 active assets");

        loan.advance(tokenId);
        assertTrue(usdc.balanceOf(address(vault)) > 99.99e18, "Vault should have .more than original balance");
        assertNotEq(usdc.balanceOf(address(owner)), startingOwnerBalance, "owner should have gained");
        assertTrue(loan.activeAssets() < amount, "should have less active assets");
    }

    function testIncreaseLoan() public {
        uint256 amount = .01e18;

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e18);
        assertEq(loan.activeAssets(),0, "ff");
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount);
        vm.stopPrank();
        assertTrue(usdc.balanceOf(address(user)) > .01e18, "User should have more than loan");

        assertEq(loan.activeAssets(),.01e18, "ff");
        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount, "Balance should be .01e18");
        assertEq(borrower, user);

        vm.startPrank(user);
        loan.increaseLoan(tokenId, amount);
        vm.stopPrank();

        (balance, borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance> amount, "Balance should be more than amount");
        assertEq(borrower, user);
        assertEq(loan.activeAssets(),0.02e18, "ff");

        assertEq(usdc.balanceOf(address(user)), 0.02e18 + startingUserBalance, "User should have .02e18");
        assertEq(usdc.balanceOf(address(vault)), 99.98e18, "Loan should have .01e18");
        
    }



    function testLoanFullPayoff() public {
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(user), 100e18);
        vm.stopPrank();

        uint256 amount = .01e18;

        assertEq(votingEscrow.ownerOf(tokenId), address(user), "User should own token");

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance, "User should have startingUserBalance");
        assertEq(usdc.balanceOf(address(vault)), 100e18);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(tokenId, amount);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(user)), .01e18+startingUserBalance, "User should have .01e18");
        assertEq(usdc.balanceOf(address(vault)), 99.99e18, "Loan should have 97e18");

        assertEq(votingEscrow.ownerOf(tokenId), address(loan));

        vm.startPrank(user);
        usdc.approve(address(loan), 1e18);
        loan.pay(tokenId, 0);
        loan.claimCollateral(tokenId);
        vm.stopPrank();

        assertEq(votingEscrow.ownerOf(tokenId), address(user));
        assertTrue(usdc.balanceOf(address(user)) < startingUserBalance, "User should have less than starting balance");
        assertTrue(usdc.balanceOf(address(vault)) > 100e18, "Loan should have more than initial balance");

        rateCalculator.setInterestRate(100, 100);
    }


}

