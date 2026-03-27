// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactoryConfig} from "./PortfolioFactoryConfig.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title NFTPortfolioFactoryConfig
 * @dev Extends PortfolioFactoryConfig with veNFT collateral tracking.
 *      Tracks tokenIds per portfolio account and total tokens in the factory.
 *      Called by CollateralManager/DynamicCollateralManager on add/remove.
 */
contract NFTPortfolioFactoryConfig is PortfolioFactoryConfig {
    using EnumerableSet for EnumerableSet.UintSet;

    struct CollateralTrackerData {
        mapping(address portfolio => mapping(address asset => EnumerableSet.UintSet)) portfolioTokens;
        mapping(address asset => EnumerableSet.UintSet) factoryTokens;
    }

    bytes32 private constant TRACKER_STORAGE_POSITION = keccak256("storage.NFTPortfolioFactoryConfig.CollateralTracker");

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

    function onCollateralAdded(address asset, uint256 id) external override onlyPortfolio {
        CollateralTrackerData storage data = _getTrackerData();
        if (data.portfolioTokens[msg.sender][asset].add(id)) {
            data.factoryTokens[asset].add(id);
        }
    }

    function onCollateralRemoved(address asset, uint256 id) external override onlyPortfolio {
        CollateralTrackerData storage data = _getTrackerData();
        if (data.portfolioTokens[msg.sender][asset].remove(id)) {
            data.factoryTokens[asset].remove(id);
        }
    }

    // ── View functions ──

    function getTokensByPortfolio(address portfolio, address asset) external view returns (uint256[] memory) {
        return _getTrackerData().portfolioTokens[portfolio][asset].values();
    }

    function getTokenCountByPortfolio(address portfolio, address asset) external view returns (uint256) {
        return _getTrackerData().portfolioTokens[portfolio][asset].length();
    }

    function getFactoryTokenCount(address asset) external view returns (uint256) {
        return _getTrackerData().factoryTokens[asset].length();
    }

    function getFactoryTokens(address asset) external view returns (uint256[] memory) {
        return _getTrackerData().factoryTokens[asset].values();
    }

    function factoryHasToken(address asset, uint256 tokenId) external view returns (bool) {
        return _getTrackerData().factoryTokens[asset].contains(tokenId);
    }

    function hasToken(address portfolio, address asset, uint256 tokenId) external view returns (bool) {
        return _getTrackerData().portfolioTokens[portfolio][asset].contains(tokenId);
    }

}
