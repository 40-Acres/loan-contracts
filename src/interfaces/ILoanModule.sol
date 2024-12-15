// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../libraries/LoanLibrary.sol";

using LoanLibrary for LoanLibrary.LoanInfo;

interface ILoanModule {
    function create(address _token,uint256 _tokenId, uint256 _loanAmount, address _borrower) external;
    function getLoanDetails(uint256 _tokenId) external view returns (LoanLibrary.LoanInfo memory);
    function advance(uint256 tokenId) external;
    function payLoan(address _module, uint256 _tokenId, uint256 _amount) external;
}
