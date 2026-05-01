// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface ISequencerLivenessCheck {
    event FeedSet(address indexed feed);
    event GracePeriodSet(uint256 gracePeriod);
    event LiquidationOverrideLtvSet(uint256 ltv);

    /// @notice Sequencer is reporting up AND post-recovery grace period has elapsed.
    function isUp() external view returns (bool);

    /// @notice Alias of isUp() for callsite clarity at borrow / withdraw entry points.
    function isBorrowAllowed() external view returns (bool);
    function getFeed() external view returns (address);
    function getGracePeriod() external view returns (uint256);
    function getLiquidationOverrideLtv() external view returns (uint256);

    function setFeed(address feed) external;
    function setGracePeriod(uint256 gracePeriodSeconds) external;
    function setLiquidationOverrideLtv(uint256 ltv) external;
}
