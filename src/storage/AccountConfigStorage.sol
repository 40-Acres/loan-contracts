// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AccountConfigStorage
 */
contract AccountConfigStorage is Ownable {
    constructor() Ownable(msg.sender) {}
    // Token storage data using named storage slot
    struct AccountConfigStorageData {
        mapping(address => bool) approvedContracts;
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
}