// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

interface IFlashLoanProvider {
    function flashLoan(uint256 amount, bytes calldata data) external;
}