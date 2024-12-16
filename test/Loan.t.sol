// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/Loan.sol";
import { AerodromeVenft } from "../src/modules/base/AerodromeVenft.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockVotingEscrow} from "./mocks/MockVotingEscrow.sol";
import { MockVoter } from "./mocks/MockVoter.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";

contract LoanTest is Test {
    Loan public loan;
    MockVotingEscrow public votingEscrow;
    ERC20Mock public mockUsdc;
    ERC20Mock public mockWeth;
    AerodromeVenft public module;
    IVoter public voter;

    address owner;
    address user;
    Vault vault;
    uint256 internal userPrivateKey;
    uint256 internal ownerPrivateKey;
    uint256 internal vaultPrivateKey;
    uint256 version;

    function setUp() public {
        userPrivateKey = 0xdeadbeef;
        ownerPrivateKey = 0x123;
        version = 0;

        owner = vm.addr(ownerPrivateKey);
        user = vm.addr(userPrivateKey);
        votingEscrow = new MockVotingEscrow(user, 1);
        mockUsdc = new ERC20Mock();
        mockWeth = new ERC20Mock();

        loan = new Loan(address(mockUsdc));
        vault = new Vault(address(mockUsdc), address(loan));
        voter = new MockVoter(address(votingEscrow), address(mockUsdc), address(mockWeth));
        module = new AerodromeVenft(address(mockUsdc), address(0), address(loan), address(votingEscrow), address(voter), address(vault));
        mockUsdc.mint(address(voter), 100e18);
        mockUsdc.mint(address(vault), 100e18);
        loan.registerModule(address(votingEscrow), address(module), version);
        loan.setVault(address(vault));
        loan.transferOwnership(owner);
    }

    function testOwner() public view {
        address o = loan.owner();
        assertEq(o, owner);
    }

    function testNftOwner() public {
        uint256 tokenId = 1;
        assertEq(votingEscrow.ownerOf(tokenId), address(user));
    }

    function testLoanRequest() public {
        uint256 tokenId = 1;
        uint256 amount = .5e18;
        uint256 expiration = block.timestamp + 1000;
        uint256 endTimestamp = block.timestamp + 1000;

        assertEq(mockUsdc.balanceOf(address(user)), 0);
        assertEq(mockUsdc.balanceOf(address(vault)), 100e18);
        vm.startPrank(user);
        loan.requestLoan(address(votingEscrow), tokenId, amount);
        vm.stopPrank();
        assertEq(mockUsdc.balanceOf(address(user)), .5e18);
        assertEq(mockUsdc.balanceOf(address(vault)), 99.5e18);

        (uint256 balance, address borrower) = loan.getLoanDetails(address(votingEscrow), tokenId);
        assertEq(balance, .5004e18);
        assertEq(borrower, user);


        // owner of token should be the module
        assertEq(votingEscrow.ownerOf(tokenId), address(module));
    }


    function testLoanVotingAdvance() public {
        uint256 tokenId = 1;
        uint256 amount = 50e18;
        uint256 expiration = block.timestamp + 1000;
        uint256 endTimestamp = block.timestamp + 1000;

        assertEq(mockUsdc.balanceOf(address(user)), 0);
        assertEq(mockUsdc.balanceOf(address(vault)), 100e18);
        vm.startPrank(user);
        loan.requestLoan(address(votingEscrow), tokenId, amount);
        vm.stopPrank();
        assertEq(mockUsdc.balanceOf(address(user)), 50e18, "User should have 50e18");
        assertEq(mockUsdc.balanceOf(address(vault)), 50e18, "Loan should have 50e18");

        (uint256 balance, address borrower) = loan.getLoanDetails(address(votingEscrow), tokenId);
        assertEq(balance, 50.04e18, "Balance should be 50e18");
        assertEq(borrower, user);


        // owner of token should be the module
        assertEq(votingEscrow.ownerOf(tokenId), address(module));

        assertEq(mockUsdc.balanceOf(address(vault)), 50e18, "Vault should have 50e18");
        loan.advance(address(votingEscrow), tokenId, version);
        assertEq(mockUsdc.balanceOf(address(owner)), .25e18, "owner should have .25e18");
        assertEq(mockUsdc.balanceOf(address(vault)), 50.75e18, "Vault should have 50.75e18");
    }



    function testIncreaseLoan() public {
        uint256 tokenId = 1;
        uint256 amount = 50e18;
        uint256 expiration = block.timestamp + 1000;
        uint256 endTimestamp = block.timestamp + 1000;

        assertEq(mockUsdc.balanceOf(address(user)), 0);
        assertEq(mockUsdc.balanceOf(address(vault)), 100e18);
        assertEq(loan.activeAssets(),0, "ff");
        vm.startPrank(user);
        loan.requestLoan(address(votingEscrow), tokenId, amount);
        vm.stopPrank();
        assertEq(mockUsdc.balanceOf(address(user)), 50e18, "User should have 50e18");
        assertEq(mockUsdc.balanceOf(address(vault)), 50e18, "Loan should have 50e18");

        assertEq(loan.activeAssets(),50e18, "ff");
        (uint256 balance, address borrower) = loan.getLoanDetails(address(votingEscrow), tokenId);
        assertEq(balance, 50.04e18, "Balance should be 50e18");
        assertEq(borrower, user);

        vm.startPrank(user);
        loan.increaseLoan(address(votingEscrow), tokenId, amount);
        vm.stopPrank();

        (balance, borrower) = loan.getLoanDetails(address(votingEscrow), tokenId);
        assertEq(balance, 100.08e18, "Balance should be 50e18");
        assertEq(borrower, user);

        assertEq(mockUsdc.balanceOf(address(user)), 100e18, "User should have 50e18");
        assertEq(mockUsdc.balanceOf(address(vault)), 0e18, "Loan should have 50e18");
        
    }


    function testLoanPayoff() public {
        uint256 tokenId = 1;
        uint256 amount = 3e18;
        uint256 expiration = block.timestamp + 1000;
        uint256 endTimestamp = block.timestamp + 1000;


        assertEq(mockUsdc.balanceOf(address(user)), 0, "User should have 0");
        assertEq(mockUsdc.balanceOf(address(vault)), 100e18);
        vm.startPrank(user);
        loan.requestLoan(address(votingEscrow), tokenId, amount);
        vm.stopPrank();
        assertEq(mockUsdc.balanceOf(address(user)), 3e18, "User should have 3e18");
        assertEq(mockUsdc.balanceOf(address(vault)), 97e18, "Loan should have 97e18");

        (uint256 balance, address borrower) = loan.getLoanDetails(address(votingEscrow), tokenId);
        assertEq(balance, 3.0024e18, "Balance should be 3e18");
        assertEq(borrower, user);
        assertEq(mockUsdc.balanceOf(address(vault)), 97e18, "ff");
        assertEq(loan.activeAssets(), 3e18, "ff");


        // owner of token should be the module
        assertEq(votingEscrow.ownerOf(tokenId), address(module));

        loan.advance(address(votingEscrow), tokenId, version);
        assertEq(mockUsdc.balanceOf(address(vault)), 97.75e18, "ff");
        assertEq(mockUsdc.balanceOf(address(owner)), .25e18, "ff");
        assertEq(loan.activeAssets(), 3e18- 0.75e18, "ff");


        loan.advance(address(votingEscrow), tokenId, version);
        assertEq(mockUsdc.balanceOf(address(vault)), 98.5e18, "eef");
        assertEq(mockUsdc.balanceOf(address(owner)), .5e18, "eeff");
        loan.advance(address(votingEscrow), tokenId, version);

        assertEq(mockUsdc.balanceOf(address(vault)), 99.25e18, "dd");
        assertEq(mockUsdc.balanceOf(address(owner)), .75e18, "dd");
        loan.advance(address(votingEscrow), tokenId, version);
        assertEq(mockUsdc.balanceOf(address(vault)), 100e18, "Vault should have .1e18");
        assertEq(mockUsdc.balanceOf(address(owner)), 1e18, "Voter should have .2e18");
        loan.advance(address(votingEscrow), tokenId, version);
        assertEq(mockUsdc.balanceOf(address(vault)), 100.0024e18, "Vault should have .1e18");
        assertEq(mockUsdc.balanceOf(address(owner)), 1.0006e18, "Voter should have .2e18");
        loan.advance(address(votingEscrow), tokenId, version);
        assertEq(loan.activeAssets(),0, "ff");

    }
}