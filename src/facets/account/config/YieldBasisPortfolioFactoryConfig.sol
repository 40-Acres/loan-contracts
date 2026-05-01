// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactoryConfig} from "./PortfolioFactoryConfig.sol";

/**
 * @title YieldBasisPortfolioFactoryConfig
 * @dev Extends PortfolioFactoryConfig with YieldBasis LP-specific protocol settings.
 *      `stakedGaugeMode` is a factory-wide directive: when true, deposits made to
 *      portfolio accounts under this factory auto-stake their LP into the gauge.
 *      Per-account convergence happens lazily on next deposit/withdraw, or via the
 *      facet's per-account admin sweep.
 */
contract YieldBasisPortfolioFactoryConfig is PortfolioFactoryConfig {
    struct YieldBasisConfigData {
        bool stakedGaugeMode;
    }

    bytes32 private constant YB_CONFIG_STORAGE_POSITION = keccak256("storage.YieldBasisPortfolioFactoryConfig");

    event StakedGaugeModeUpdated(bool oldValue, bool newValue);

    function _getYbConfig() internal pure returns (YieldBasisConfigData storage data) {
        bytes32 position = YB_CONFIG_STORAGE_POSITION;
        assembly {
            data.slot := position
        }
    }

    function setStakedGaugeMode(bool value) external onlyOwner {
        YieldBasisConfigData storage data = _getYbConfig();
        bool oldValue = data.stakedGaugeMode;
        data.stakedGaugeMode = value;
        emit StakedGaugeModeUpdated(oldValue, value);
    }

    function getStakedGaugeMode() external view returns (bool) {
        return _getYbConfig().stakedGaugeMode;
    }
}
