// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IPortfolioFactoryConfig {
    function getPortfolioFactoryConfig() external view returns (address);
    function getDebtToken() external view returns (address);
}