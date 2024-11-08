// SPDX-License-Identifier:
pragma solidity ^0.8.28;

library LoanLibrary {
    struct LoanInfo {
        address tokenAddress;
        uint256 tokenId;
        uint256 initialLoanAmount;
        uint256 amountPaid;
        uint256 startTime;
        uint256 endTime;
        address borrower;
        bool active;
    }
}