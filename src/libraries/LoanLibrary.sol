// SPDX-License-Identifier:
pragma solidity ^0.8.28;

library LoanLibrary {
    struct LoanInfo {
        address tokenAddress;
        uint256 tokenId;
        uint256 balance;
        address borrower;
    }
}