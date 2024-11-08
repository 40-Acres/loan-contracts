// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../libraries/LoanLibrary.sol";

using LoanLibrary for LoanLibrary.LoanInfo;

interface IModule {
    function createLoan(address _tokenAddress, uint256 _tokenId, address borrower, uint256 expiration) external returns (LoanLibrary.LoanInfo memory);
    function paybackLoan() external;
    function getLoan() external;
}

struct LoanInfo {
    address tokenAddress;
    uint256 tokenId;
    uint256 interest;
    uint256 initialLoanAmount;
    uint256 amountPaid;
    uint256 startTime;
    uint256 endTime;
    address borrower;
    bool active;
}
