// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactoryConfig} from "./PortfolioFactoryConfig.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title YieldBasisPortfolioFactoryConfig
 * @dev Extends PortfolioFactoryConfig with YieldBasis LP-specific protocol settings.
 *      `stakedGaugeMode` is a factory-wide directive: when true, deposits made to
 *      portfolio accounts under this factory auto-stake their LP into the gauge.
 *      Per-account convergence happens lazily on next deposit/withdraw, or via the
 *      facet's per-account admin sweep.
 *
 *      Also tracks the set of portfolio accounts currently holding YB LP collateral
 *      per LP token, so the backend can enumerate accounts that need maintenance
 *      (setMode / claim / etc). Hooks fire transition-only from the YB collateral
 *      manager; the `id` param of the inherited collateral hooks is ignored.
 */
contract YieldBasisPortfolioFactoryConfig is PortfolioFactoryConfig {
    using EnumerableSet for EnumerableSet.AddressSet;

    struct YieldBasisConfigData {
        bool stakedGaugeMode;
    }

    struct AccountTrackerData {
        mapping(address lp => EnumerableSet.AddressSet accounts) accountsByLp;
    }

    bytes32 private constant YB_CONFIG_STORAGE_POSITION = keccak256("storage.YieldBasisPortfolioFactoryConfig");
    bytes32 private constant YB_TRACKER_STORAGE_POSITION = keccak256("storage.YieldBasisPortfolioFactoryConfig.AccountTracker");

    event StakedGaugeModeUpdated(bool oldValue, bool newValue);

    error NotPortfolio(address caller);

    function _getYbConfig() internal pure returns (YieldBasisConfigData storage data) {
        bytes32 position = YB_CONFIG_STORAGE_POSITION;
        assembly {
            data.slot := position
        }
    }

    function _getTrackerData() internal pure returns (AccountTrackerData storage data) {
        bytes32 position = YB_TRACKER_STORAGE_POSITION;
        assembly {
            data.slot := position
        }
    }

    modifier onlyPortfolio() {
        address factory = getPortfolioFactory();
        require(factory != address(0), "Factory not set");
        if (!PortfolioFactory(factory).isPortfolio(msg.sender)) revert NotPortfolio(msg.sender);
        _;
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

    // ── Collateral hooks (id ignored — YB has no per-tokenId concept) ──

    function onCollateralAdded(address lp, uint256) external override onlyPortfolio {
        _getTrackerData().accountsByLp[lp].add(msg.sender);
    }

    function onCollateralRemoved(address lp, uint256) external override onlyPortfolio {
        _getTrackerData().accountsByLp[lp].remove(msg.sender);
    }

    // ── View functions ──

    function getAccountsByLp(address lp) external view returns (address[] memory) {
        return _getTrackerData().accountsByLp[lp].values();
    }

    function getAccountCountByLp(address lp) external view returns (uint256) {
        return _getTrackerData().accountsByLp[lp].length();
    }

    function lpHasAccount(address lp, address account) external view returns (bool) {
        return _getTrackerData().accountsByLp[lp].contains(account);
    }
}
