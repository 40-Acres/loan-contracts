// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


interface ILoanModule {
    function initializeLoan(uint256 _tokenId) external returns (uint256);
    function getMaxLoan(uint256 _tokenId) external view returns (uint256);
    function getRewards(uint256 tokenId) external returns (uint256);
    function claimCollateral(uint256 _tokenId, address _to) external;
}
