// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ISequencerLivenessCheck} from "./ISequencerLivenessCheck.sol";
import {IChainlinkSequencerUptimeFeed} from "./IChainlinkSequencerUptimeFeed.sol";

/**
 * @title SequencerLivenessCheck
 * @notice L2 sequencer-uptime predicate. Answers whether the sequencer has
 *         been up long enough for the protocol to trust on-chain valuations.
 *
 *         Owner is expected to be the same governance multisig that controls
 *         each PortfolioFactoryConfig that points at this contract — there is
 *         no role-tier split inside this contract.
 *
 *         No staleness check on `updatedAt`: L2 Sequencer Uptime feeds only
 *         emit a new round on status change, so `updatedAt` is legitimately
 *         old whenever the sequencer has been continuously up.
 */
contract SequencerLivenessCheck is ISequencerLivenessCheck, Ownable2Step {
    error GracePeriodOutOfRange();
    error LiquidationOverrideOutOfRange();

    uint256 public constant MIN_GRACE_PERIOD = 600;
    uint256 public constant MAX_GRACE_PERIOD = 24 hours;
    uint256 public constant MIN_LIQUIDATION_OVERRIDE_LTV = 100;
    uint256 public constant MAX_LIQUIDATION_OVERRIDE_LTV = 200;

    IChainlinkSequencerUptimeFeed internal _feed;
    uint256 internal _gracePeriod;
    uint256 internal _liquidationOverrideLtv;

    constructor(
        address owner_,
        address feed_,
        uint256 gracePeriodSeconds,
        uint256 liquidationOverrideLtv_
    ) Ownable(owner_) {
        if (gracePeriodSeconds < MIN_GRACE_PERIOD || gracePeriodSeconds > MAX_GRACE_PERIOD) {
            revert GracePeriodOutOfRange();
        }
        if (
            liquidationOverrideLtv_ < MIN_LIQUIDATION_OVERRIDE_LTV ||
            liquidationOverrideLtv_ > MAX_LIQUIDATION_OVERRIDE_LTV
        ) {
            revert LiquidationOverrideOutOfRange();
        }

        _feed = IChainlinkSequencerUptimeFeed(feed_);
        _gracePeriod = gracePeriodSeconds;
        _liquidationOverrideLtv = liquidationOverrideLtv_;

        emit FeedSet(feed_);
        emit GracePeriodSet(gracePeriodSeconds);
        emit LiquidationOverrideLtvSet(liquidationOverrideLtv_);
    }

    function isUp() public view override returns (bool) {
        IChainlinkSequencerUptimeFeed feed = _feed;
        if (address(feed) == address(0)) return true;

        try feed.latestRoundData() returns (
            uint80,
            int256 answer,
            uint256 startedAt,
            uint256,
            uint80
        ) {
            // Misconfigured feed returning all zeros must not be treated as "up since unix epoch".
            if (startedAt == 0) return false;
            // Strict-greater: at the exact grace boundary the gate is still closed.
            return answer == 0 && (block.timestamp - startedAt) > _gracePeriod;
        } catch {
            return false;
        }
    }

    function isBorrowAllowed() external view override returns (bool) {
        return isUp();
    }

    function setFeed(address feed_) external override onlyOwner {
        _feed = IChainlinkSequencerUptimeFeed(feed_);
        emit FeedSet(feed_);
    }

    function setGracePeriod(uint256 gracePeriodSeconds) external override onlyOwner {
        if (gracePeriodSeconds < MIN_GRACE_PERIOD || gracePeriodSeconds > MAX_GRACE_PERIOD) {
            revert GracePeriodOutOfRange();
        }
        _gracePeriod = gracePeriodSeconds;
        emit GracePeriodSet(gracePeriodSeconds);
    }

    function setLiquidationOverrideLtv(uint256 ltv) external override onlyOwner {
        if (ltv < MIN_LIQUIDATION_OVERRIDE_LTV || ltv > MAX_LIQUIDATION_OVERRIDE_LTV) {
            revert LiquidationOverrideOutOfRange();
        }
        _liquidationOverrideLtv = ltv;
        emit LiquidationOverrideLtvSet(ltv);
    }

    function getFeed() external view override returns (address) {
        return address(_feed);
    }

    function getGracePeriod() external view override returns (uint256) {
        return _gracePeriod;
    }

    function getLiquidationOverrideLtv() external view override returns (uint256) {
        return _liquidationOverrideLtv;
    }
}
