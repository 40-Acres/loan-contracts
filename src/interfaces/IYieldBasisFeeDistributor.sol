// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IYieldBasisFeeDistributor
 * @dev Interface for YieldBasis FeeDistributor contract on Ethereum
 * Based on Curve's FeeDistributor pattern
 * Contract: 0xD11b416573EbC59b6B2387DA0D2c0D1b3b1F7A90
 */
interface IYieldBasisFeeDistributor {
    /// @notice Claim fees for an address
    /// @param _addr Address to claim fees for
    /// @return Amount of fees claimed
    function claim(address _addr) external returns (uint256);

    /// @notice Claim fees for multiple addresses in a single call
    /// @param _receivers Array of addresses to claim for (max 20, stops at first zero address)
    /// @return True if claims were successful
    function claim_many(address[20] calldata _receivers) external returns (bool);

    /// @notice Update the token checkpoint
    /// @dev Calculates tokens to be distributed per week
    function checkpoint_token() external;

    /// @notice Update the veYB total supply checkpoint
    /// @dev Reduces gas costs for subsequent claims
    function checkpoint_total_supply() external;

    /// @notice Check if checkpoint can be called by anyone
    /// @return True if checkpointing is enabled
    function can_checkpoint_token() external view returns (bool);

    /// @notice Get the timestamp of the last token checkpoint
    /// @return Last checkpoint timestamp
    function last_token_time() external view returns (uint256);

    /// @notice Get the start time of the fee distribution
    /// @return Start timestamp
    function start_time() external view returns (uint256);

    /// @notice Get the time cursor for a specific user
    /// @param _addr User address
    /// @return Last claim timestamp for the user
    function time_cursor_of(address _addr) external view returns (uint256);

    /// @notice Get the veYB contract address
    /// @return Address of the veYB contract
    function voting_escrow() external view returns (address);
}
