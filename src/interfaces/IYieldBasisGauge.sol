// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IYieldBasisGauge
 * @dev Interface for YieldBasis Gauge contracts (ERC4626-compatible liquidity gauges)
 * Gauges accept ybBTC LP tokens and distribute YB token emissions to stakers.
 */
interface IYieldBasisGauge {
    /// @notice Claim rewards earned by a user
    /// @param reward The reward token to claim (defaults to YB)
    /// @param user The user to claim for
    /// @return Amount of rewards claimed
    function claim(address reward, address user) external returns (uint256);

    /// @notice Preview claimable rewards for a user
    /// @param reward The reward token to query
    /// @param user The user to query
    /// @return Amount of rewards claimable
    function preview_claim(address reward, address user) external view returns (uint256);

    /// @notice Deposit ybBTC LP tokens into the gauge to earn rewards
    /// @param assets Amount of ybBTC to stake
    /// @param receiver Address to receive gauge shares
    /// @return shares Amount of gauge shares minted
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Preview shares that would be burned for a given asset withdrawal
    /// @param assets Amount of ybBTC to preview
    /// @return shares Amount of gauge shares that would be burned
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    /// @notice Withdraw ybBTC LP tokens from the gauge
    /// @param assets Amount of ybBTC to unstake
    /// @param receiver Address to receive ybBTC
    /// @param owner Owner of the gauge shares to burn
    /// @return shares Amount of gauge shares burned
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Redeem gauge shares for ybBTC LP tokens
    /// @param shares Amount of gauge shares to redeem
    /// @param receiver Address to receive ybBTC
    /// @param owner Owner of the gauge shares
    /// @return assets Amount of ybBTC received
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Get the underlying LP token (ybBTC) address
    /// @return The ybBTC token address
    function asset() external view returns (address);

    /// @notice Get gauge share balance of an address
    /// @param owner The address to query
    /// @return Gauge share balance
    function balanceOf(address owner) external view returns (uint256);

    /// @notice Total gauge shares outstanding
    /// @return Total supply of gauge shares
    function totalSupply() external view returns (uint256);

    /// @notice Total ybBTC LP tokens managed by the gauge
    /// @return Total underlying assets
    function totalAssets() external view returns (uint256);

    /// @notice Convert gauge shares to underlying LP token amount
    /// @param shares Amount of gauge shares
    /// @return assets Equivalent LP token amount
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Convert LP token amount to gauge shares
    /// @param assets Amount of LP tokens
    /// @return shares Equivalent gauge shares
    function convertToShares(uint256 assets) external view returns (uint256 shares);
}
