// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ProtocolTimeLibrary} from "../../../libraries/ProtocolTimeLibrary.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title VotingConfig
 */
contract VotingConfig is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    constructor() {
        _disableInitializers();
    }
    
    function initialize(address owner) initializer public {
        __Ownable_init(owner); 
    }

    event ApprovedPool(address pool, bool approved);
    event ApprovedLaunchpadPool(address pool, bool approved, address launchpadToken);
    /**
     * @dev This function is used to authorize upgrades to the contract.
     *      It restricts the upgradeability to only the contract owner.
     * @param newImplementation The address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    // Token storage data using named storage slot
    struct VotingConfigData {
        mapping(address => bool) approvedPools;
        mapping(uint256 epoch => mapping(address => address)) launchpadPoolTokenForEpoch;
        EnumerableSet.AddressSet approvedPoolsList;
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
        if(approved) {
            votingStorage.approvedPoolsList.add(pool);
        } else {
            votingStorage.approvedPoolsList.remove(pool);
        }
        emit ApprovedPool(pool, approved);
    }

    function isApprovedPool(address pool) public view returns (bool) {
        VotingConfigData storage votingStorage = _getVotingConfig();
        return votingStorage.approvedPools[pool];
    }

    function getApprovedPoolsList() public view returns (address[] memory) {
        VotingConfigData storage votingStorage = _getVotingConfig();
        return votingStorage.approvedPoolsList.values();
    }

    function getApprovedPoolsListLength() public view returns (uint256) {
        VotingConfigData storage votingStorage = _getVotingConfig();
        return votingStorage.approvedPoolsList.length();
    }

    function getApprovedPoolAtIndex(uint256 index) public view returns (address) {
        VotingConfigData storage votingStorage = _getVotingConfig();
        return votingStorage.approvedPoolsList.at(index);
    }

    function setLaunchpadPoolTokenForNextEpoch(address pool, address launchpadToken) public onlyOwner {
        setLaunchpadPoolTokenForEpoch(ProtocolTimeLibrary.epochNext(block.timestamp), pool, launchpadToken);
    }

    function setLaunchpadPoolTokenForEpoch(uint256 epoch, address pool, address launchpadToken) public onlyOwner {
        VotingConfigData storage votingStorage = _getVotingConfig();
        votingStorage.launchpadPoolTokenForEpoch[ProtocolTimeLibrary.epochStart(epoch)][pool] = launchpadToken;
        votingStorage.approvedPools[pool] = true;
        emit ApprovedLaunchpadPool(pool, true, launchpadToken);
    }

    function isLaunchpadPool(uint256 epoch, address pool) public view returns (bool) {
        VotingConfigData storage votingStorage = _getVotingConfig();
        return votingStorage.launchpadPoolTokenForEpoch[ProtocolTimeLibrary.epochStart(epoch)][pool] != address(0);
    }

    function isLaunchpadPoolForCurrentEpoch(address pool) public view returns (bool) {
        return isLaunchpadPool(ProtocolTimeLibrary.epochStart(block.timestamp), pool);
    }

    function getLaunchpadPoolTokenForEpoch(uint256 epoch, address pool) public view returns (address) {
        VotingConfigData storage votingStorage = _getVotingConfig();
        return votingStorage.launchpadPoolTokenForEpoch[ProtocolTimeLibrary.epochStart(epoch)][pool];
    }

    function getLaunchpadPoolTokenForCurrentEpoch(address pool) public view returns (address) {
        return getLaunchpadPoolTokenForEpoch(ProtocolTimeLibrary.epochStart(block.timestamp), pool);
    }

}