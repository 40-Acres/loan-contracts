// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface ICollateralFacet {
    function getTotalDebt() external view returns (uint256);
    function getUnpaidFees() external view returns (uint256);
    function getMaxLoan() external view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply);
    function enforceCollateralRequirements() external view returns (bool success);
}