// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ISequencerLivenessCheck} from "./ISequencerLivenessCheck.sol";

interface IPortfolioFactoryConfigLivenessView {
    function getSequencerLivenessCheck() external view returns (address);
}

/// @notice Internal helpers for action-level sequencer-uptime gating.
///         Facets call assertUp(_config()) at borrow / withdraw entry points.
library SequencerLivenessLib {
    error SequencerDown();

    function assertUp(address portfolioFactoryConfig) internal view {
        address guard = IPortfolioFactoryConfigLivenessView(portfolioFactoryConfig).getSequencerLivenessCheck();
        if (guard == address(0)) return;
        if (!ISequencerLivenessCheck(guard).isBorrowAllowed()) revert SequencerDown();
    }
}
