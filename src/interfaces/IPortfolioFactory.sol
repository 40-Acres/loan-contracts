// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IPortfolioFactory {
    event AccountCreated(address indexed user, address indexed portfolio);

    error AccountAlreadyExists(address user);
    error AccountCreationFailed(address user);

    /// @notice Returns the facet registry address
    function facetRegistry() external view returns (address);

    /// @notice Returns the portfolio manager address
    function portfolioManager() external view returns (address);

    /// @notice Returns the portfolio address for a given owner
    /// @param owner The owner address
    /// @return The portfolio address
    function portfolios(address owner) external view returns (address);

    /// @notice Returns the owner address for a given portfolio
    /// @param portfolio The portfolio address
    /// @return The owner address
    function owners(address portfolio) external view returns (address);

    /// @notice Creates a new FortyAcresPortfolioAccount using centralized facet registry
    /// @param user The address for which to create a portfolio
    /// @return portfolio The address of the deployed FortyAcresPortfolioAccount contract
    function createAccount(address user) external returns (address portfolio);

    /// @notice Get facet registry version
    /// @return Current registry version
    function getRegistryVersion() external view returns (uint256);

    /// @notice Returns the owner of a portfolio
    /// @param portfolio The portfolio address
    /// @return The owner address
    function ownerOf(address portfolio) external view returns (address);

    /// @notice Returns the portfolio address for an owner
    /// @param owner The owner address
    /// @return The portfolio address
    function portfolioOf(address owner) external view returns (address);

    /// @notice Checks if portfolio exists (check if owner exists)
    /// @param _portfolio The portfolio address to check
    /// @return True if the portfolio exists
    function isPortfolio(address _portfolio) external view returns (bool);

    /// @notice Returns all portfolio addresses
    /// @return Array of all portfolio addresses
    function getAllPortfolios() external view returns (address[] memory);

    /// @notice Returns the total number of portfolios
    /// @return The number of portfolios
    function getPortfoliosLength() external view returns (uint256);

    /// @notice Returns the portfolio at a specific index
    /// @param index The index of the portfolio
    /// @return The portfolio address at the given index
    function getPortfolio(uint256 index) external view returns (address);
}

