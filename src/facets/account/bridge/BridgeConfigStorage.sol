// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/**
 * @title BridgeConfigStorage
 */
contract BridgeConfigStorage is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    constructor() {
        _disableInitializers();
    }
    
    function initialize(address owner) initializer public {
        __Ownable_init(owner); 
    }

    event ApprovedBridge(address pool, bool approved);
    
    /**
     * @dev This function is used to authorize upgrades to the contract.
     *      It restricts the upgradeability to only the contract owner.
     * @param newImplementation The address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    // Token storage data using named storage slot
    struct BridgeConfigStorageData {
        mapping(address => bool) approvedBridges;

    }

    // Named storage slot for account data
    bytes32 private constant ACCOUNT_STORAGE_POSITION = keccak256("storage.BridgeConfigStorage");

    /**
     * @dev Get token storage data from named storage slot
     */
    function _getBridgeConfigStorage() internal pure returns (BridgeConfigStorageData storage votingStorage) {
        bytes32 position = ACCOUNT_STORAGE_POSITION;
        assembly {
            votingStorage.slot := position
        }
    }

    function setApprovedBridge(address bridge, bool approved) public onlyOwner {
        BridgeConfigStorageData storage bridgeStorage = _getBridgeConfigStorage();
        bridgeStorage.approvedBridges[bridge] = approved;
        emit ApprovedBridge(bridge, approved);
    }

    function isApprovedBridge(address bridge) public view returns (bool) {
        BridgeConfigStorageData storage bridgeStorage = _getBridgeConfigStorage();
        return bridgeStorage.approvedBridges[bridge];
    }
}