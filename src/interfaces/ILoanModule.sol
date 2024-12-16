// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


interface ILoanModule {
    function initializeLoan(uint256 _tokenId) external returns (uint256);
    function repay(uint256 _tokenId) external returns (uint256);
    function getMaxLoan(uint256 _tokenId) external view returns (uint256);
}
