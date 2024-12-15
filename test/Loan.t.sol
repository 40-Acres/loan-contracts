// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/Loan.sol";
import { AerodromeVenft } from "../src/modules/base/AerodromeVenft.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockVotingEscrow} from "./mocks/MockVotingEscrow.sol";
import { MockVoter } from "./mocks/MockVoter.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import "../src/libraries/LoanLibrary.sol";

contract LoanTest is Test {
    using ECDSA for bytes32;
    using LoanLibrary for LoanLibrary.LoanInfo;

    Loan public loan;
    MockVotingEscrow public votingEscrow;
    ERC20Mock public mockUsdc;
    ERC20Mock public mockWeth;
    AerodromeVenft public module;
    IVoter public voter;

    address owner;
    address user;
    address vault;
    uint256 internal userPrivateKey;
    uint256 internal ownerPrivateKey;
    uint256 internal vaultPrivateKey;

    function setUp() public {
        userPrivateKey = 0xdeadbeef;
        vaultPrivateKey = 0x2;
        ownerPrivateKey = 0x123;

        vault = vm.addr(vaultPrivateKey);
        owner = vm.addr(ownerPrivateKey);
        user = vm.addr(userPrivateKey);
        votingEscrow = new MockVotingEscrow(user, 1);
        mockUsdc = new ERC20Mock();
        mockWeth = new ERC20Mock();
        loan = new Loan(address(mockUsdc));
        voter = new MockVoter(address(votingEscrow), address(mockUsdc), address(mockWeth));
        module = new AerodromeVenft(address(mockUsdc), address(0), address(loan), address(votingEscrow), address(voter));
        mockUsdc.mint(address(voter), 100e18);
        mockUsdc.mint(address(loan), 100e18);
        loan.RegisterModule(address(votingEscrow), address(module));
        loan.transferOwnership(owner);
    }

    function testOwner() public view {
        address o = loan.owner();
        assertEq(o, owner);
    }

    function testValidSignature() public {
        uint256 tokenId = 1;
        uint256 amount = 50e18;
        
        bytes32 message = keccak256(abi.encodePacked(votingEscrow, tokenId, amount));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, message);
        

        // verify the signature
        assertEq(owner, loan.verifySignature(message, v, r, s));

    }

    function testLoanRequest() public {
        uint256 tokenId = 1;
        uint256 amount = .5e18;
        uint256 expiration = block.timestamp + 1000;
        uint256 endTimestamp = block.timestamp + 1000;
        uint256 interestRate = 10 * 52;

        bytes32 message = keccak256(abi.encodePacked(votingEscrow, tokenId, amount, expiration, endTimestamp));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, message);

        assertEq(mockUsdc.balanceOf(address(user)), 0);
        assertEq(mockUsdc.balanceOf(address(loan)), 100e18);
        vm.startPrank(user);
        loan.RequestLoan(address(votingEscrow), tokenId, amount, interestRate, expiration, endTimestamp, message, v, r, s);
        vm.stopPrank();
        assertEq(mockUsdc.balanceOf(address(user)), .5e18);
        assertEq(mockUsdc.balanceOf(address(loan)), 99.5e18);

        (uint256 balance, uint256 endTime, address borrower, uint256 fees) = loan.getLoanDetails(address(votingEscrow), tokenId);
        assertEq(balance, .5e18);
        assertEq(endTime, expiration);
        assertEq(borrower, user);
        assertEq(fees, .05e18);


        // owner of token should be the module
        assertEq(votingEscrow.ownerOf(tokenId), address(module));
    }


    function testLoanVotingAdvance() public {
        uint256 tokenId = 1;
        uint256 amount = 50e18;
        uint256 expiration = block.timestamp + 1000;
        uint256 endTimestamp = block.timestamp + 1000;
        uint256 interestRate = 10 * 52;

        bytes32 message = keccak256(abi.encodePacked(votingEscrow, tokenId, amount, expiration, endTimestamp));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, message);

        assertEq(mockUsdc.balanceOf(address(user)), 0);
        assertEq(mockUsdc.balanceOf(address(loan)), 100e18);
        assertEq(mockUsdc.balanceOf(address(0x2)), 0);
        vm.startPrank(user);
        loan.RequestLoan(address(votingEscrow), tokenId, amount, interestRate, expiration, endTimestamp, message, v, r, s);
        vm.stopPrank();
        assertEq(mockUsdc.balanceOf(address(user)), 50e18, "User should have 50e18");
        assertEq(mockUsdc.balanceOf(address(loan)), 50e18, "Loan should have 50e18");

        (uint256 balance, uint256 endTime, address borrower, uint256 fees) = loan.getLoanDetails(address(votingEscrow), tokenId);
        assertEq(balance, 50e18, "Balance should be 50e18");
        assertEq(endTime, expiration);
        assertEq(borrower, user);
        assertEq(fees, 5e18, "Fees should be 5e18");


        // owner of token should be the module
        assertEq(votingEscrow.ownerOf(tokenId), address(module));

        loan.advance(address(votingEscrow), tokenId);
        assertEq(mockUsdc.balanceOf(address(0x2)), .75e18, "Vault should have .1e18");
        assertEq(mockUsdc.balanceOf(address(0x1)), .25e18, "Voter should have .2e18");
        assertEq(mockUsdc.balanceOf(address(loan)), 50e18, "Loan should have 50e18+.7e18");
    }


    function testLoanAdvance() public {
        uint256 tokenId = 1;
        uint256 amount = 3e18;
        uint256 expiration = block.timestamp + 1000;
        uint256 endTimestamp = block.timestamp + 1000;
        uint256 interestRate = 1 * 52;

        bytes32 message = keccak256(abi.encodePacked(votingEscrow, tokenId, amount, expiration, endTimestamp));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, message);

        assertEq(mockUsdc.balanceOf(address(user)), 0, "User should have 0");
        assertEq(mockUsdc.balanceOf(address(loan)), 100e18);
        assertEq(mockUsdc.balanceOf(address(0x2)), 0, "Vault should have 0");
        vm.startPrank(user);
        loan.RequestLoan(address(votingEscrow), tokenId, amount, interestRate, expiration, endTimestamp, message, v, r, s);
        vm.stopPrank();
        assertEq(mockUsdc.balanceOf(address(user)), 3e18, "User should have 3e18");
        assertEq(mockUsdc.balanceOf(address(loan)), 97e18, "Loan should have 97e18");

        (uint256 balance, uint256 endTime, address borrower, uint256 fees) = loan.getLoanDetails(address(votingEscrow), tokenId);
        assertEq(balance, amount, "Balance should be 3e18");
        assertEq(fees, .0027e18, "Fees should be 3e18*.01e18");
        assertEq(endTime, expiration);
        assertEq(borrower, user);


        // owner of token should be the module
        assertEq(votingEscrow.ownerOf(tokenId), address(module));

        loan.advance(address(votingEscrow), tokenId);
        assertEq(mockUsdc.balanceOf(address(0x2)), .002025e18, "ff");
        assertEq(mockUsdc.balanceOf(address(0x1)), .000675e18, "ff");
        assertEq(mockUsdc.balanceOf(address(loan)), 97e18+ .9973e18, "ffsd");


        loan.advance(address(votingEscrow), tokenId);
        assertEq(mockUsdc.balanceOf(address(0x2)), .0225e18 + .002025e18, "eef");
        assertEq(mockUsdc.balanceOf(address(0x1)), .0075e18 + 0.00675e18, "eeff");
        assertEq(mockUsdc.balanceOf(address(loan)), 97e18 + .97e18 * 2, "eefff");
        loan.advance(address(votingEscrow), tokenId);
        assertEq(mockUsdc.balanceOf(address(0x2)), .0225e18 * 3, "dd");
        assertEq(mockUsdc.balanceOf(address(0x1)), .0075e18 * 3, "dd");
        assertEq(mockUsdc.balanceOf(address(loan)), 97e18 + .97e18 * 3, "dd");
        loan.advance(address(votingEscrow), tokenId);
        assertEq(mockUsdc.balanceOf(address(0x2)), .0225e18 * 4, "Vault should have .1e18");
        assertEq(mockUsdc.balanceOf(address(0x1)), .0075e18 * 4, "Voter should have .2e18");
        assertEq(mockUsdc.balanceOf(address(loan)), 100e18);
        loan.advance(address(votingEscrow), tokenId);

    }
}
