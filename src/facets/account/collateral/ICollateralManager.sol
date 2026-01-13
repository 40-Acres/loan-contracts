// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface ICollateralManager {
    function getTotalLockedCollateral() external view returns (uint256);
    function getTotalDebt() external view returns (uint256);
    function getUnpaidFees() external view returns (uint256);
    function getMaxLoan() external view returns (uint256, uint256);
    function getOriginTimestamp(uint256 tokenId) external view returns (uint256);
    function getCollateralToken() external view returns (address);
    function getLockedCollateral(uint256 tokenId) external view returns (uint256);
    function addLockedCollateral(uint256 tokenId) external;
    function removeLockedCollateral(uint256 tokenId) external;
}