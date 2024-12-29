// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/Loan.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { MockVoter } from "./mocks/MockVoter.sol";
import { IVoter } from "src/interfaces/IVoter.sol";
import { Vault } from "src/Vault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVotingEscrow } from "../src/interfaces/IVotingEscrow.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(address minter, uint256 minterAllowedAmount) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);

}

contract LoanTest is Test {
    IUSDC usdc = IUSDC(0x2Ce6311ddAE708829bc0784C967b7d77D19FD779);
    IVotingEscrow votingEscrow = IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    address pool = address(0x6cDcb1C4A4D1C3C6d054b27AC5B77e89eAFb971d);

    // deployed contracts
    Vault vault;
    Loan public loan;

    address owner;
    address user;
    uint256 version;
    uint256 tokenId = 64196;

    function setUp() public {
        version = 0;

        owner = vm.addr(0x123);
        user = votingEscrow.ownerOf(tokenId);

        loan = new Loan(address(usdc), pool);
        vault = new Vault(address(usdc), address(loan));
        loan.setVault(address(vault));
        loan.transferOwnership(owner);
        // allow this test contract to mint USDC
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(voter), 100e18);
        usdc.mint(address(vault), 100e18);
        vm.stopPrank();
    }

    function testOwner() public view {
        address o = loan.owner();
        assertEq(o, owner);
    }

    function testNftOwner() public {
        assertEq(votingEscrow.ownerOf(tokenId), address(user));
    }

    function testLoanRequest() public {
        uint256 amount = .5e18;
        uint256 expiration = block.timestamp + 1000;
        uint256 endTimestamp = block.timestamp + 1000;

        assertEq(usdc.balanceOf(address(user)), 0);
        assertEq(usdc.balanceOf(address(vault)), 100e18);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(address(votingEscrow), tokenId, amount);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(user)), .5e18);
        assertEq(usdc.balanceOf(address(vault)), 99.5e18);

        (uint256 balance, address borrower) = loan.getLoanDetails(address(votingEscrow), tokenId);
        assertEq(balance, .5004e18);
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));
    }


    function testLoanVotingAdvance() public {
        uint256 amount = 50e18;
        uint256 expiration = block.timestamp + 1000;
        uint256 endTimestamp = block.timestamp + 1000;

        assertEq(usdc.balanceOf(address(user)), 0);
        assertEq(usdc.balanceOf(address(vault)), 100e18);
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(loan), tokenId);
        loan.requestLoan(address(votingEscrow), tokenId, amount);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(user)), 50e18, "User should have 50e18");
        assertEq(usdc.balanceOf(address(vault)), 50e18, "Loan should have 50e18");

        (uint256 balance, address borrower) = loan.getLoanDetails(address(votingEscrow), tokenId);
        assertEq(balance, 50.04e18, "Balance should be 50e18");
        assertEq(borrower, user);


        // owner of token should be the loan
        assertEq(votingEscrow.ownerOf(tokenId), address(loan));

        assertEq(usdc.balanceOf(address(vault)), 50e18, "Vault should have 50e18");
        loan.advance(address(votingEscrow), tokenId);
        assertEq(usdc.balanceOf(address(owner)), .25e18, "owner should have .25e18");
        assertEq(usdc.balanceOf(address(vault)), 50.75e18, "Vault should have 50.75e18");
    }



    // function testIncreaseLoan() public {
    //     uint256 amount = 50e18;
    //     uint256 expiration = block.timestamp + 1000;
    //     uint256 endTimestamp = block.timestamp + 1000;

    //     assertEq(usdc.balanceOf(address(user)), 0);
    //     assertEq(usdc.balanceOf(address(vault)), 100e18);
    //     assertEq(loan.activeAssets(),0, "ff");
    //     vm.startPrank(user);
    //     IERC721(address(votingEscrow)).approve(address(loan), tokenId);
    //     loan.requestLoan(address(votingEscrow), tokenId, amount);
    //     vm.stopPrank();
    //     assertEq(usdc.balanceOf(address(user)), 50e18, "User should have 50e18");
    //     assertEq(usdc.balanceOf(address(vault)), 50e18, "Loan should have 50e18");

    //     assertEq(loan.activeAssets(),50e18, "ff");
    //     (uint256 balance, address borrower) = loan.getLoanDetails(address(votingEscrow), tokenId);
    //     assertEq(balance, 50.04e18, "Balance should be 50e18");
    //     assertEq(borrower, user);

    //     vm.startPrank(user);
    //     IERC721(address(votingEscrow)).approve(address(loan), tokenId);
    //     loan.increaseLoan(address(votingEscrow), tokenId, amount);
    //     vm.stopPrank();

    //     (balance, borrower) = loan.getLoanDetails(address(votingEscrow), tokenId);
    //     assertEq(balance, 100.08e18, "Balance should be 50e18");
    //     assertEq(borrower, user);

    //     assertEq(usdc.balanceOf(address(user)), 100e18, "User should have 50e18");
    //     assertEq(usdc.balanceOf(address(vault)), 0e18, "Loan should have 50e18");
        
    // }


//     function testLoanPayoff() public {
//         uint256 amount = 3e18;
//         uint256 expiration = block.timestamp + 1000;
//         uint256 endTimestamp = block.timestamp + 1000;



//         assertEq(votingEscrow.ownerOf(tokenId), address(user), "User should own token");

//         assertEq(usdc.balanceOf(address(user)), 0, "User should have 0");
//         assertEq(usdc.balanceOf(address(vault)), 100e18);
//         vm.startPrank(user);
//         IERC721(address(votingEscrow)).approve(address(loan), tokenId);
//         loan.requestLoan(address(votingEscrow), tokenId, amount);
//         vm.stopPrank();
//         assertEq(usdc.balanceOf(address(user)), 3e18, "User should have 3e18");
//         assertEq(usdc.balanceOf(address(vault)), 97e18, "Loan should have 97e18");

//         (uint256 balance, address borrower) = loan.getLoanDetails(address(votingEscrow), tokenId);
//         assertEq(balance, 3.0024e18, "Balance should be 3e18");
//         assertEq(borrower, user);
//         assertEq(usdc.balanceOf(address(vault)), 97e18, "ff");
//         assertEq(loan.activeAssets(), 3e18, "ff");


//         // owner of token should be the loan
//         assertEq(votingEscrow.ownerOf(tokenId), address(loan));

//         loan.advance(address(votingEscrow), tokenId, version);
//         assertEq(usdc.balanceOf(address(vault)), 97.75e18, "ff");
//         assertEq(usdc.balanceOf(address(owner)), .25e18, "ff");
//         assertEq(loan.activeAssets(), 3e18- 0.75e18, "ff");


//         loan.advance(address(votingEscrow), tokenId, version);
//         assertEq(usdc.balanceOf(address(vault)), 98.5e18, "eef");
//         assertEq(usdc.balanceOf(address(owner)), .5e18, "eeff");
//         loan.advance(address(votingEscrow), tokenId, version);

//         assertEq(usdc.balanceOf(address(vault)), 99.25e18, "dd");
//         assertEq(usdc.balanceOf(address(owner)), .75e18, "dd");
//         loan.advance(address(votingEscrow), tokenId, version);
//         assertEq(usdc.balanceOf(address(vault)), 100e18, "Vault should have .1e18");
//         assertEq(usdc.balanceOf(address(owner)), 1e18, "Voter should have .2e18");
//         loan.advance(address(votingEscrow), tokenId, version);
//         assertEq(usdc.balanceOf(address(vault)), 100.0024e18, "Vault should have .1e18");
//         assertEq(usdc.balanceOf(address(owner)), 1.0006e18, "Voter should have .2e18");
//         loan.advance(address(votingEscrow), tokenId, version);
//         assertEq(loan.activeAssets(),0, "ff");



//         (balance, borrower) = loan.getLoanDetails(address(votingEscrow), tokenId);
//         assertEq(balance, 0, "Balance should be 0");


//         try loan.claimCollateral(address(votingEscrow), tokenId, version){
//             assertEq(true, false, "Should have thrown");
//         } catch Error(string memory reason) {
//             assertEq(reason, "Only the borrower can claim collateral", "Should have thrown");
//         }
//         assertEq(votingEscrow.ownerOf(tokenId), address(loan), "Owner should be loan");
//         vm.startPrank(user);
//         loan.claimCollateral(address(votingEscrow), tokenId, version);
//         vm.stopPrank();


//         assertEq(votingEscrow.ownerOf(tokenId), address(user), "Owner should be user");
//     }

//     function testLoanFullPayoff() public {
//         uint256 amount = 3e18;
//         uint256 expiration = block.timestamp + 1000;
//         uint256 endTimestamp = block.timestamp + 1000;



//         assertEq(votingEscrow.ownerOf(tokenId), address(user), "User should own token");

//         assertEq(usdc.balanceOf(address(user)), 0, "User should have 0");
//         assertEq(usdc.balanceOf(address(vault)), 100e18);
//         vm.startPrank(user);
//         IERC721(address(votingEscrow)).approve(address(loan), tokenId);
//         loan.requestLoan(address(votingEscrow), tokenId, amount);
//         vm.stopPrank();
//         assertEq(usdc.balanceOf(address(user)), 3e18, "User should have 3e18");
//         assertEq(usdc.balanceOf(address(vault)), 97e18, "Loan should have 97e18");


//         vm.startPrank(user);
//         usdc.approve(address(loan), 3e18);
//         loan.pay(address(votingEscrow), tokenId, 3e18);
//         vm.stopPrank();

//         assertEq(usdc.balanceOf(address(user)), 0e18, "User should have 3e18");
//         assertEq(usdc.balanceOf(address(vault)), 100e18, "Loan should have 97e18");
//     }
}
