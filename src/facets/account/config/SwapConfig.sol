// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/**
 * @title SwapConfig
 */
contract SwapConfig is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    constructor() {
        _disableInitializers();
    }
    
    function initialize(address owner) initializer public {
        __Ownable_init(owner); 
    }
    
    /**
     * @dev This function is used to authorize upgrades to the contract.
     *      It restricts the upgradeability to only the contract owner.
     * @param newImplementation The address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    // Token storage data using named storage slot
    struct SwapConfigData {
        mapping(address => bool) approvedSwapTargets;
    }

    // Named storage slot for account data
    bytes32 private constant ACCOUNT_STORAGE_POSITION = keccak256("storage.SwapConfig");

    /**
     * @dev Get token storage data from named storage slot
     */
    function _getSwapConfig() internal pure returns (SwapConfigData storage swapConfigData) {
        bytes32 position = ACCOUNT_STORAGE_POSITION;
        assembly {
            swapConfigData.slot := position
        }
    }

    function approveSwapTarget(address swapTarget) public onlyOwner {
        SwapConfigData storage swapConfigData = _getSwapConfig();
        swapConfigData.approvedSwapTargets[swapTarget] = true;
    }

    function isApprovedSwapTarget(address swapTarget) public view returns (bool) {
        SwapConfigData storage swapConfigData = _getSwapConfig();
        return swapConfigData.approvedSwapTargets[swapTarget];
    }
}