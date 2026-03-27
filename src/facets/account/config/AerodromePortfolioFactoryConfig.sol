// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactoryConfig} from "./PortfolioFactoryConfig.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title AerodromePortfolioFactoryConfig
 * @dev Extends PortfolioFactoryConfig with veNFT collateral tracking.
 *      Tracks tokenIds per portfolio account and total tokens in the factory.
 *      Called by CollateralManager/DynamicCollateralManager on add/remove.
 */
contract AerodromePortfolioFactoryConfig is PortfolioFactoryConfig {
    using EnumerableSet for EnumerableSet.UintSet;

    struct CollateralTrackerData {
        mapping(address portfolio => EnumerableSet.UintSet) portfolioTokens;
        EnumerableSet.UintSet factoryTokens;
    }

    bytes32 private constant TRACKER_STORAGE_POSITION = keccak256("storage.AerodromePortfolioFactoryConfig.CollateralTracker");

    function _getTrackerData() internal pure returns (CollateralTrackerData storage data) {
        bytes32 position = TRACKER_STORAGE_POSITION;
        assembly {
            data.slot := position
        }
    }

    error NotPortfolio(address caller);

    modifier onlyPortfolio() {
        address factory = getPortfolioFactory();
        require(factory != address(0), "Factory not set");
        if (!PortfolioFactory(factory).isPortfolio(msg.sender)) revert NotPortfolio(msg.sender);
        _;
    }

    // ── Collateral hooks ──

    function onCollateralAdded(address, uint256 id) external override onlyPortfolio {
        CollateralTrackerData storage data = _getTrackerData();
        if (data.portfolioTokens[msg.sender].add(id)) {
            data.factoryTokens.add(id);
        }
    }

    function onCollateralRemoved(address, uint256 id) external override onlyPortfolio {
        CollateralTrackerData storage data = _getTrackerData();
        if (data.portfolioTokens[msg.sender].remove(id)) {
            data.factoryTokens.remove(id);
        }
    }


    function getTokensByPortfolio(address portfolio) external view returns (uint256[] memory) {
        return _getTrackerData().portfolioTokens[portfolio].values();
    }

    function getTokenCountByPortfolio(address portfolio) external view returns (uint256) {
        return _getTrackerData().portfolioTokens[portfolio].length();
    }

    function getFactoryTokenCount() external view returns (uint256) {
        return _getTrackerData().factoryTokens.length();
    }

    function getFactoryTokens() external view returns (uint256[] memory) {
        return _getTrackerData().factoryTokens.values();
    }

    function factoryHasToken(uint256 tokenId) external view returns (bool) {
        return _getTrackerData().factoryTokens.contains(tokenId);
    }

    function hasToken(address portfolio, uint256 tokenId) external view returns (bool) {
        return _getTrackerData().portfolioTokens[portfolio].contains(tokenId);
    }

}
