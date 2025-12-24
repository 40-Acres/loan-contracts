// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IPortfolioAccountConfig {
    function getPortfolioAccountConfig() external view returns (address);
}