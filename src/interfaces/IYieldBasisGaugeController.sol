// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IYieldBasisGaugeController
 * @dev Interface for YieldBasis GaugeController contract on Ethereum
 * Contract: 0x1Be14811A3a06F6aF4fA64310a636e1Df04c1c21
 *
 * veYB holders vote on gauge weights to direct YB emissions to liquidity pools.
 * Weights update at the start of each epoch week.
 * 10-day cooldown between vote changes per gauge.
 */
interface IYieldBasisGaugeController {
    /// @notice Vote user slopes struct returned by vote_user_slopes
    struct VoteUserSlope {
        uint256 slope;
        uint256 bias;
        uint256 power;
        uint256 end;
    }

    /// @notice Allocate voting power for changing pool weights
    /// @param gauge_addrs Array of gauge addresses to vote for
    /// @param user_weights Array of weights in bps (0-10000, where 10000 = 100%)
    function vote_for_gauge_weights(address[] calldata gauge_addrs, uint256[] calldata user_weights) external;

    /// @notice Get current gauge weight
    /// @param gauge Gauge address
    /// @return Current gauge weight
    function get_gauge_weight(address gauge) external view returns (uint256);

    /// @notice Get gauge weight (alternative getter)
    /// @param gauge Gauge address
    /// @return Current gauge weight
    function gauge_weight(address gauge) external view returns (uint256);

    /// @notice Get total weight across all gauges
    /// @return Total weight
    function gauge_weight_sum() external view returns (uint256);

    /// @notice Get user's vote info for a gauge
    /// @param user User address
    /// @param gauge Gauge address
    /// @return VoteUserSlope struct with slope, bias, power, end
    function vote_user_slopes(address user, address gauge) external view returns (VoteUserSlope memory);

    /// @notice Get user's used voting power
    /// @param user User address
    /// @return Used voting power (out of 10000)
    function vote_user_power(address user) external view returns (uint256);

    /// @notice Get timestamp of user's last vote for a gauge
    /// @param user User address
    /// @param gauge Gauge address
    /// @return Timestamp of last vote
    function last_user_vote(address user, address gauge) external view returns (uint256);

    /// @notice Get number of gauges
    /// @return Number of gauges
    function n_gauges() external view returns (uint256);

    /// @notice Get gauge address by index
    /// @param index Gauge index
    /// @return Gauge address
    function gauges(uint256 index) external view returns (address);

    /// @notice Check if gauge is killed (disabled)
    /// @param gauge Gauge address
    /// @return True if gauge is killed
    function is_killed(address gauge) external view returns (bool);

    /// @notice Get gauge relative weight (percentage of total)
    /// @param gauge Gauge address
    /// @return Relative weight
    function gauge_relative_weight(address gauge) external view returns (uint256);

    /// @notice Get time weight for a gauge
    /// @param gauge Gauge address
    /// @return Time weight (non-zero if gauge is registered)
    function time_weight(address gauge) external view returns (uint256);

    /// @notice Checkpoint for a specific gauge
    /// @param gauge Gauge address
    function checkpoint(address gauge) external;

    /// @notice Check if user is allowed to transfer veYB
    /// @param user User address
    /// @return True if transfer is allowed
    function ve_transfer_allowed(address user) external view returns (bool);

    /// @notice Get the voting escrow contract address
    /// @return Voting escrow address
    function VOTING_ESCROW() external view returns (address);

    /// @notice Get the token contract address
    /// @return Token address
    function TOKEN() external view returns (address);
}
