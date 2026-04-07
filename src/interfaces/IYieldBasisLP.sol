// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IYieldBasisLP
 * @dev Interface for YieldBasis Liquidity Token (LT) contracts.
 * LT tokens represent shares in a 2x leveraged BTC/crvUSD (or ETH/crvUSD) Curve pool.
 * pricePerShare increases over time as trading fees accrue.
 *
 * NOT ERC4626 — uses its own deposit/withdraw interface.
 */
interface IYieldBasisLP {
    /// @notice Non-manipulatable fair price per share oracle
    /// @return Price per LP token in underlying asset terms (18 decimals)
    function pricePerShare() external view returns (uint256);

    /// @notice LP token decimals (18)
    function decimals() external view returns (uint8);

    /// @notice Preview how much underlying asset would be received for burning shares
    /// @param shares Amount of LP shares to preview
    /// @return assets Amount of underlying asset that would be received (includes Curve slippage)
    function preview_withdraw(uint256 shares) external view returns (uint256 assets);

    /// @notice Burn LP shares and receive underlying asset
    /// @param shares Amount of LP shares to burn
    /// @param min_assets Minimum underlying asset to receive (slippage protection)
    /// @param receiver Address to receive the underlying asset
    /// @return assets Amount of underlying asset received
    function withdraw(uint256 shares, uint256 min_assets, address receiver) external returns (uint256 assets);
}
