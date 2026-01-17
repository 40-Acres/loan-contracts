// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {VotingConfig} from "./VotingConfig.sol";

/**
 * @title VotingConfig
 */
contract SuperchainVotingConfig is VotingConfig {
    constructor() {
        _disableInitializers();
    }
    

    struct SuperchainVotingConfigData {
        mapping(address => bool) superchainPools;
        mapping(address => uint256) superchainPoolChainId;
        uint256 minimumWethBalance;
    }

    // Named storage slot for account data
    bytes32 private constant ACCOUNT_STORAGE_POSITION = keccak256("storage.SuperchainVotingConfig");

    /**
     * @dev Get token storage data from named storage slot
     */
    function _getSuperchainVotingConfig() internal pure returns (SuperchainVotingConfigData storage superchainVotingStorage) {
        bytes32 position = ACCOUNT_STORAGE_POSITION;
        assembly {
            superchainVotingStorage.slot := position
        }
    }
    
    /**
     * @dev Set superchain pool
     */
    function setSuperchainPool(address pool, bool approved, uint256 chainId) external onlyOwner {
        SuperchainVotingConfigData storage superchainVotingStorage = _getSuperchainVotingConfig();
        superchainVotingStorage.superchainPools[pool] = approved;
        superchainVotingStorage.superchainPoolChainId[pool] = chainId;
        super.setApprovedPool(pool, approved);
    }

    function isSuperchainPool(address pool) public view returns (bool) {
        SuperchainVotingConfigData storage superchainVotingStorage = _getSuperchainVotingConfig();
        return superchainVotingStorage.superchainPools[pool];
    }

    function setMinimumWethBalance(uint256 minimumWethBalance) external onlyOwner {
        SuperchainVotingConfigData storage superchainVotingStorage = _getSuperchainVotingConfig();
        superchainVotingStorage.minimumWethBalance = minimumWethBalance;
    }

    function getMinimumWethBalance() public view returns (uint256) {
        SuperchainVotingConfigData storage superchainVotingStorage = _getSuperchainVotingConfig();
        return superchainVotingStorage.minimumWethBalance;
    }

    function getSuperchainPoolChainId(address pool) public view returns (uint256) {
        SuperchainVotingConfigData storage superchainVotingStorage = _getSuperchainVotingConfig();
        return superchainVotingStorage.superchainPoolChainId[pool];
    }
}