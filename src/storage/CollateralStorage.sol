// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title CollateralStorage
 */
library CollateralStorage {
    // Token storage data using named storage slot
    struct CollateralStorageData {
        mapping(address => mapping(uint256 => bool)) isNonfungibleCollateral;
        mapping(address => uint256) fungibleCollateral;
        mapping(address => bool) isTotalCollateral;
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
        require(!collateralStorage.isNonfungibleCollateral[tokenAddress][assetId]);
        collateralStorage.isNonfungibleCollateral[tokenAddress][assetId] = true;
    }

    function addFungibleCollateral(
        address tokenAddress,
        uint256 amount
    ) external {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        collateralStorage.fungibleCollateral[tokenAddress] += amount;
    }

    function addTotalCollateral(
        address tokenAddress
    ) external {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        require(!collateralStorage.isTotalCollateral[tokenAddress], "Total collateral already added");
        collateralStorage.isTotalCollateral[tokenAddress] = true;
    }

    function removeNonfungibleCollateral(
        address tokenAddress,
        uint256 assetId
    ) external {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        require(collateralStorage.isNonfungibleCollateral[tokenAddress][assetId]);
        collateralStorage.isNonfungibleCollateral[tokenAddress][assetId] = false;
    }

    function removeFungibleCollateral(
        address tokenAddress,
        uint256 amount
    ) external {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        require(collateralStorage.fungibleCollateral[tokenAddress] >= amount);
        collateralStorage.fungibleCollateral[tokenAddress] -= amount;
    }

    function removeTotalCollateral(
        address tokenAddress
    ) external {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        require(collateralStorage.isTotalCollateral[tokenAddress]);
        collateralStorage.isTotalCollateral[tokenAddress] = false;
    }

    function getNonfungibleCollateral(
        address tokenAddress,
        uint256 assetId
    ) external view returns (bool) {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        return collateralStorage.isNonfungibleCollateral[tokenAddress][assetId];
    }
    
    function getFungibleCollateral(
        address tokenAddress
    ) external view returns (uint256) {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        return collateralStorage.fungibleCollateral[tokenAddress];
    }
    
    
    function getTotalCollateral(
        address tokenAddress
    ) external view returns (bool) {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        return collateralStorage.isTotalCollateral[tokenAddress];
    }
    
}