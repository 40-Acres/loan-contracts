// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";



/**
 * @title CollateralStorage
 */
library CollateralStorage {
    // Token storage data using named storage slot
    struct CollateralStorageData {
        mapping(address => mapping(address => mapping(uint256 => bool))) isNonfungibleCollateral;
        mapping(address => mapping(address => uint256)) fungibleCollateral;
        mapping(address => mapping(address => bool)) isTotalCollateral;
    }

    // Named storage slot for account data
    bytes32 private constant ACCOUNT_STORAGE_POSITION = keccak256("storage.CollateralStorage");

    /**
     * @dev Get token storage data from named storage slot
     */
    function _getCollateralStorage() internal pure returns (CollateralStorageData storage collateralStorage) {
        bytes32 position = ACCOUNT_STORAGE_POSITION;
        assembly {
            collateralStorage.slot := position
        }
    }

    function addNonfungibleCollateral(
        address tokenAddress,
        uint256 assetId
    ) external {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        require(!collateralStorage.isNonfungibleCollateral[msg.sender][tokenAddress][assetId]);
        collateralStorage.isNonfungibleCollateral[msg.sender][tokenAddress][assetId] = true;
    }

    function addFungibleCollateral(
        address tokenAddress,
        uint256 amount
    ) external {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        collateralStorage.fungibleCollateral[msg.sender][tokenAddress] += amount;
    }

    function addTotalCollateral(
        address tokenAddress
    ) external {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        require(!collateralStorage.isTotalCollateral[msg.sender][tokenAddress]);
        collateralStorage.isTotalCollateral[msg.sender][tokenAddress] = true;
    }

    function removeNonfungibleCollateral(
        address tokenAddress,
        uint256 assetId
    ) external {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        require(collateralStorage.isNonfungibleCollateral[msg.sender][tokenAddress][assetId]);
        collateralStorage.isNonfungibleCollateral[msg.sender][tokenAddress][assetId] = false;
    }

    function removeFungibleCollateral(
        address tokenAddress,
        uint256 amount
    ) external {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        require(collateralStorage.fungibleCollateral[msg.sender][tokenAddress] >= amount);
        collateralStorage.fungibleCollateral[msg.sender][tokenAddress] -= amount;
    }

    function removeTotalCollateral(
        address tokenAddress
    ) external {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        require(collateralStorage.isTotalCollateral[msg.sender][tokenAddress]);
        collateralStorage.isTotalCollateral[msg.sender][tokenAddress] = false;
    }

    function getNonfungibleCollateral(
        address tokenAddress,
        uint256 assetId
    ) external view returns (bool) {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        return collateralStorage.isNonfungibleCollateral[msg.sender][tokenAddress][assetId];
    }
    
    function getFungibleCollateral(
        address tokenAddress
    ) external view returns (uint256) {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        return collateralStorage.fungibleCollateral[msg.sender][tokenAddress];
    }
    
    
    function getTotalCollateral(
        address tokenAddress
    ) external view returns (bool) {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        return collateralStorage.isTotalCollateral[msg.sender][tokenAddress];
    }
    
    
}