// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface ICollateralFacet {
    function enforceCollateral() external view;
    function getMaxLoan() external view returns (uint256, uint256);
    function getTotalLockedCollateral() external view returns (uint256);
    function getTotalDebt() external view returns (uint256);
    function getOriginTimestamp(uint256 tokenId) external view returns (uint256);
}