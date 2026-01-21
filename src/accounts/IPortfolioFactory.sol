// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IPortfolioFactory {
    function createAccount(address user) external returns (address portfolio);
    function getRegistryVersion() external view returns (uint256);
    function ownerOf(address portfolio) external view returns (address);
    function portfolioOf(address owner) external view returns (address);
    function isPortfolio(address _portfolio) external view returns (bool);
    function getAllPortfolios() external view returns (address[] memory);
    function getPortfoliosLength() external view returns (uint256);
}