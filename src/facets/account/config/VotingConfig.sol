// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/**
 * @title VotingConfig
 */
contract VotingConfig is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    constructor() {
        _disableInitializers();
    }
    
    function initialize(address owner) initializer public {
        __Ownable_init(owner); 
    }

    event ApprovedPool(address pool, bool approved);
    
    /**
     * @dev This function is used to authorize upgrades to the contract.
     *      It restricts the upgradeability to only the contract owner.
     * @param newImplementation The address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    // Token storage data using named storage slot
    struct VotingConfigData {
        mapping(address => bool) approvedPools;
    }

    // Named storage slot for account data
    bytes32 private constant ACCOUNT_STORAGE_POSITION = keccak256("storage.VotingConfig");

    /**
     * @dev Get token storage data from named storage slot
     */
    function _getVotingConfig() internal pure returns (VotingConfigData storage votingStorage) {
        bytes32 position = ACCOUNT_STORAGE_POSITION;
        assembly {
            votingStorage.slot := position
        }
    }

    function setApprovedPool(address pool, bool approved) public onlyOwner {
        VotingConfigData storage votingStorage = _getVotingConfig();
        votingStorage.approvedPools[pool] = approved;
        emit ApprovedPool(pool, approved);
    }

    function isApprovedPool(address pool) public view returns (bool) {
        VotingConfigData storage votingStorage = _getVotingConfig();
        return votingStorage.approvedPools[pool];
    }
}