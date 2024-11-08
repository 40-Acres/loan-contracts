// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/Loan.sol";
import { VelodromeVenft } from "../src/modules/base/VelodromeVenft.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

contract LoanTest is Test {
    using ECDSA for bytes32;

    Loan public loan;
    MockERC721 public token;
    VelodromeVenft public module;

    address owner;
    address user;
    uint256 internal userPrivateKey;
    uint256 internal ownerPrivateKey;

    function setUp() public {
        userPrivateKey = 0xdeadbeef;
        ownerPrivateKey = 0x123;

        owner = vm.addr(ownerPrivateKey);
        user = vm.addr(userPrivateKey);
        loan = new Loan();
        token = new MockERC721(user, 1);
        module = new VelodromeVenft();

        loan.RegisterModule(address(token), address(module));
        loan.transferOwnership(owner);

    }

    function testOwner() public view {
        address o = loan.owner();
        assertEq(o, owner);
    }

    function testValidSignature() public {
        uint256 tokenId = 1;
        uint256 amount = 100;
        uint256 expiration = block.timestamp + 1000;
        
        bytes32 message = keccak256(abi.encodePacked(token, tokenId, amount, expiration));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, message);
        

        // verify the signature
        assertEq(owner, loan.verifySignature(message, v, r, s));

    }

    function testLoanRequest() public {
        uint256 tokenId = 1;
        uint256 amount = 100;
        uint256 expiration = block.timestamp + 1000;

        bytes32 message = keccak256(abi.encodePacked(token, tokenId, amount, expiration));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, message);

        vm.startPrank(user);
        loan.RequestLoan(address(token), tokenId, amount, expiration, message, v, r, s);
        vm.stopPrank();

        (uint256 amountPaid, uint256 startTime, uint256 endTime, address borrower, bool active) = loan.getLoanDetails(address(token), tokenId);
        assertEq(amountPaid, 0);
        assertEq(startTime, block.timestamp);
        assertEq(endTime, expiration);
        assertEq(borrower, user);
        assertEq(active, true);
    }
}
