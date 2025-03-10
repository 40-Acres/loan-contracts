// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


interface ILoan {
    function activeAssets() external view returns (uint256);
    function lastEpochReward() external view returns (uint256);
}
