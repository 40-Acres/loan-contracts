// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IChainlinkSequencerUptimeFeed} from "../../src/oracle/IChainlinkSequencerUptimeFeed.sol";

/**
 * @title MockChainlinkSequencerUptimeFeed
 * @dev Test mock for the Chainlink L2 sequencer uptime feed.
 *      State is fully settable; `latestRoundData()` can be configured to revert
 *      to exercise the `try/catch` fail-closed branch in SequencerLivenessCheck.
 */
contract MockChainlinkSequencerUptimeFeed is IChainlinkSequencerUptimeFeed {
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public roundId;
    uint80 public answeredInRound;
    bool public shouldRevert;

    function setStatus(int256 answer_, uint256 startedAt_) external {
        answer = answer_;
        startedAt = startedAt_;
        // updatedAt is not consulted by SequencerLivenessCheck — set anyway for realism.
        updatedAt = startedAt_;
        roundId = 1;
        answeredInRound = 1;
    }

    function setRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        if (shouldRevert) revert("MockFeed: forced revert");
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
