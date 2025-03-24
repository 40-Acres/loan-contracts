// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IReward {
    function rewards(uint256 id) external returns (address);
}