// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {VotingConfigStorage} from "./VotingConfigStorage.sol";

/**
 * @title VotingConfigStorage
 */
contract SuperchainVotingConfigStorage is VotingConfigStorage {
    constructor() {
        _disableInitializers();
    }
    

    struct SuperchainVotingConfigStorageData {
        mapping(address => bool) superchainPools;
        uint256 minimumWethBalance;
    }

    // Named storage slot for account data
    bytes32 private constant ACCOUNT_STORAGE_POSITION = keccak256("storage.SuperchainVotingConfigStorage");

    /**
     * @dev Get token storage data from named storage slot
     */
    function _getSuperchainVotingConfigStorage() internal pure returns (SuperchainVotingConfigStorageData storage superchainVotingStorage) {
        bytes32 position = ACCOUNT_STORAGE_POSITION;
        assembly {
            superchainVotingStorage.slot := position
        }
    }
    /**
     * @dev Set superchain pool
     */
    function setSuperchainPool(address pool, bool approved) internal {
        SuperchainVotingConfigStorageData storage superchainVotingStorage = _getSuperchainVotingConfigStorage();
        superchainVotingStorage.superchainPools[pool] = approved;
    }

    function isSuperchainPool(address pool) public view returns (bool) {
        SuperchainVotingConfigStorageData storage superchainVotingStorage = _getSuperchainVotingConfigStorage();
        return superchainVotingStorage.superchainPools[pool];
    }

    function setMinimumWethBalance(uint256 minimumWethBalance) internal {
        SuperchainVotingConfigStorageData storage superchainVotingStorage = _getSuperchainVotingConfigStorage();
        superchainVotingStorage.minimumWethBalance = minimumWethBalance;
    }

    function getMinimumWethBalance() public view returns (uint256) {
        SuperchainVotingConfigStorageData storage superchainVotingStorage = _getSuperchainVotingConfigStorage();
        return superchainVotingStorage.minimumWethBalance;
    }
}