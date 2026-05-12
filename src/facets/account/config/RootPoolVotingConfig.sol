// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {VotingConfig} from "./VotingConfig.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IRootPool} from "../../../interfaces/IRootPool.sol";

/**
 * @title RootPoolVotingConfig
 * @dev VotingConfig variant that identifies superchain pools by their deploying
 *      factory rather than maintaining a per-pool allowlist. A pool is treated
 *      as a superchain pool iff `IRootPool(pool).factory()` returns an address
 *      registered here. This avoids the need to preemptively enumerate every
 *      root pool — the set of root-pool factories is small and stable.
 */
contract RootPoolVotingConfig is VotingConfig {
    using EnumerableSet for EnumerableSet.AddressSet;

    error ZeroAddress();

    event RootPoolFactoryAdded(address indexed factory);
    event RootPoolFactoryRemoved(address indexed factory);

    struct RootPoolVotingConfigData {
        EnumerableSet.AddressSet rootPoolFactories;
        uint256 minimumLockedBalancePerPool;
    }

    bytes32 private constant STORAGE_POSITION = keccak256("storage.RootPoolVotingConfig");

    constructor() {
        _disableInitializers();
    }

    function _getRootPoolVotingConfig() internal pure returns (RootPoolVotingConfigData storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }

    function setRootPoolFactory(address factory, bool approved) external onlyOwner {
        if (factory == address(0)) revert ZeroAddress();
        RootPoolVotingConfigData storage s = _getRootPoolVotingConfig();
        if (approved) {
            if (s.rootPoolFactories.add(factory)) {
                emit RootPoolFactoryAdded(factory);
            }
        } else {
            if (s.rootPoolFactories.remove(factory)) {
                emit RootPoolFactoryRemoved(factory);
            }
        }
    }

    function isRootPoolFactory(address factory) public view returns (bool) {
        return _getRootPoolVotingConfig().rootPoolFactories.contains(factory);
    }

    function getRootPoolFactoriesList() public view returns (address[] memory) {
        return _getRootPoolVotingConfig().rootPoolFactories.values();
    }

    function getRootPoolFactoriesListLength() public view returns (uint256) {
        return _getRootPoolVotingConfig().rootPoolFactories.length();
    }

    function getRootPoolFactoryAtIndex(uint256 index) public view returns (address) {
        return _getRootPoolVotingConfig().rootPoolFactories.at(index);
    }

    /**
     * @dev Runtime probe — a pool is a superchain pool if its factory()
     *      returns an allowlisted root-pool factory. The facet performs a
     *      second-stage chainid() check to confirm and identify the leaf chain.
     */
    function isSuperchainPool(address pool) public view returns (bool) {
        try IRootPool(pool).factory() returns (address f) {
            return isRootPoolFactory(f);
        } catch {
            return false;
        }
    }

    function setMinimumLockedBalancePerPool(uint256 minimumLockedBalancePerPool) external onlyOwner {
        _getRootPoolVotingConfig().minimumLockedBalancePerPool = minimumLockedBalancePerPool;
    }

    function getMinimumLockedBalancePerPool() public view returns (uint256) {
        return _getRootPoolVotingConfig().minimumLockedBalancePerPool;
    }
}
