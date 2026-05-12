// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IRootPool {
    function chainid() external view returns (uint256);
    function factory() external view returns (address);
}
