// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/**
 * @title AccountConfigStorage
 */
contract AccountConfigStorage is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    constructor() {
        _disableInitializers();
    }
    
    function initialize() initializer public {
        __Ownable_init(msg.sender); 
    }
    
    /**
     * @dev This function is used to authorize upgrades to the contract.
     *      It restricts the upgradeability to only the contract owner.
     * @param newImplementation The address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    // Token storage data using named storage slot
    struct AccountConfigStorageData {
        mapping(address => bool) approvedContracts;
        mapping(address => bool) authorizedCallers;
        address loanContract;
    }

    // Named storage slot for account data
    bytes32 private constant ACCOUNT_STORAGE_POSITION = keccak256("storage.AccountConfigStorage");

    /**
     * @dev Get token storage data from named storage slot
     */
    function _getAccountConfigStorage() internal pure returns (AccountConfigStorageData storage collateralStorage) {
        bytes32 position = ACCOUNT_STORAGE_POSITION;
        assembly {
            collateralStorage.slot := position
        }
    }

    function setApprovedContract(address addr, bool approved) public onlyOwner {
        AccountConfigStorageData storage collateralStorage = _getAccountConfigStorage();
        collateralStorage.approvedContracts[addr] = approved;
    }

    function isApprovedContract(address addr) public view returns (bool) {
        AccountConfigStorageData storage collateralStorage = _getAccountConfigStorage();
        return collateralStorage.approvedContracts[addr];
    }

    function setAuthorizedCaller(address addr, bool authorized) public onlyOwner {
        AccountConfigStorageData storage collateralStorage = _getAccountConfigStorage();
        collateralStorage.authorizedCallers[addr] = authorized;
    }

    function isAuthorizedCaller(address addr) public view returns (bool) {
        AccountConfigStorageData storage collateralStorage = _getAccountConfigStorage();
        return collateralStorage.authorizedCallers[addr];
    }

    function setLoanContract(address addr) public onlyOwner {
        AccountConfigStorageData storage collateralStorage = _getAccountConfigStorage();
        collateralStorage.loanContract = addr;
    }

    function getLoanContract() public view returns (address) {
        AccountConfigStorageData storage collateralStorage = _getAccountConfigStorage();
        return collateralStorage.loanContract;
    }
}