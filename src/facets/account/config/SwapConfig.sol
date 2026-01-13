// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
/**
 * @title SwapConfig
 */
contract SwapConfig is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;
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
        EnumerableSet.AddressSet approvedSwapTargetsList;
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

    function setApprovedSwapTarget(address swapTarget, bool approved) public onlyOwner {
        SwapConfigData storage swapConfigData = _getSwapConfig();
        swapConfigData.approvedSwapTargets[swapTarget] = approved;
        if(approved) {
            swapConfigData.approvedSwapTargetsList.add(swapTarget);
        } else {
            swapConfigData.approvedSwapTargetsList.remove(swapTarget);
        }
    }

    function isApprovedSwapTarget(address swapTarget) public view returns (bool) {
        SwapConfigData storage swapConfigData = _getSwapConfig();
        return swapConfigData.approvedSwapTargets[swapTarget];
    }

    function getApprovedSwapTargetsList() public view returns (address[] memory) {
        SwapConfigData storage swapConfigData = _getSwapConfig();
        return swapConfigData.approvedSwapTargetsList.values();
    }

    function getApprovedSwapTargetsListLength() public view returns (uint256) {
        SwapConfigData storage swapConfigData = _getSwapConfig();
        return swapConfigData.approvedSwapTargetsList.length();
    }

    function getApprovedSwapTargetAtIndex(uint256 index) public view returns (address) {
        SwapConfigData storage swapConfigData = _getSwapConfig();
        return swapConfigData.approvedSwapTargetsList.at(index);
    }
}