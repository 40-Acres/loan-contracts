// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IMinter {
    function updatePeriod() external returns (uint256 _period);
}