// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../accounts/PortfolioFactory.sol";

/**
 * @title LibCollateral
 * @dev Library for managing collateral storage in diamond pattern
 */
library LibCollateral {
    
    // Storage for NFT data
    struct NonfungibleAsset {
        address tokenAddress;
        uint256 assetId; // Generic identifier for ERC721 (tokenId), ERC1155 (tokenId), ERC20 (0 or unique ID)
        address assetHandler; // Contract that handles this asset's operations (voting, claiming, loans)
    }

    struct FungibleAsset {
        address tokenAddress;
        uint256 amount; // amount of the asset
        address assetHandler; // Contract that handles this asset's operations (voting, claiming, loans)
    }

    // TotalCollateral is for assets (like xPHAR) where it is a erc20 but the account total balance is used as collateral
    struct TotalCollateral {
        address tokenAddress;
        address assetHandler; // Contract that handles this asset's operations (voting, claiming, loans)
    }

    // Token storage data using named storage slot
    struct CollateralStorageData {
        PortfolioFactory portfolioFactory;
        mapping(address => mapping(address => mapping(uint256 => bool))) isNonfungibleCollateral;
        mapping(address => mapping(address => uint256)) fungibleCollateral;
        mapping(address => mapping(address => bool)) isTotalCollateral;
    }

    // Named storage slot for collateral data
    bytes32 private constant COLLATERAL_STORAGE_POSITION = keccak256("storage.CollateralStorage");

    /**
     * @dev Get collateral storage data from named storage slot
     */
    function collateralStorage() internal pure returns (CollateralStorageData storage collateralStorageData) {
        bytes32 position = COLLATERAL_STORAGE_POSITION;
        assembly {
            collateralStorageData.slot := position
        }
    }

    /**
     * @dev Enforce that the caller is a portfolio account
     */
    function enforceIsPortfolioAccount() internal view {
        CollateralStorageData storage collateralStorageData = collateralStorage();
        require(collateralStorageData.portfolioFactory.isAccount(msg.sender), "LibCollateral: Not a portfolio account");
    }

    /**
     * @dev Initialize the collateral storage with portfolio factory
     * @param portfolioFactory The portfolio factory address
     */
    function initCollateralStorage(address portfolioFactory) internal {
        CollateralStorageData storage collateralStorageData = collateralStorage();
        collateralStorageData.portfolioFactory = PortfolioFactory(portfolioFactory);
    }

    /**
     * @dev Add nonfungible collateral for an account
     * @param account The account address
     * @param tokenAddress The address of the token contract
     * @param assetId The asset ID (tokenId for ERC721)
     */
    function addNonfungibleCollateral(
        address account,
        address tokenAddress,
        uint256 assetId
    ) internal {
        CollateralStorageData storage collateralStorageData = collateralStorage();
        require(!collateralStorageData.isNonfungibleCollateral[account][tokenAddress][assetId], "LibCollateral: Asset already collateral");
        collateralStorageData.isNonfungibleCollateral[account][tokenAddress][assetId] = true;
    }

    /**
     * @dev Add fungible collateral for an account
     * @param account The account address
     * @param tokenAddress The address of the token contract
     * @param amount The amount to add
     */
    function addFungibleCollateral(
        address account,
        address tokenAddress,
        uint256 amount
    ) internal {
        CollateralStorageData storage collateralStorageData = collateralStorage();
        collateralStorageData.fungibleCollateral[account][tokenAddress] += amount;
    }

    /**
     * @dev Add total collateral for an account
     * @param account The account address
     * @param tokenAddress The address of the token contract
     */
    function addTotalCollateral(
        address account,
        address tokenAddress
    ) internal {
        CollateralStorageData storage collateralStorageData = collateralStorage();
        collateralStorageData.isTotalCollateral[account][tokenAddress] = true;
    }

    /**
     * @dev Remove nonfungible collateral for an account
     * @param account The account address
     * @param tokenAddress The address of the token contract
     * @param assetId The asset ID (tokenId for ERC721)
     */
    function removeNonfungibleCollateral(
        address account,
        address tokenAddress,
        uint256 assetId
    ) internal {
        CollateralStorageData storage collateralStorageData = collateralStorage();
        require(collateralStorageData.isNonfungibleCollateral[account][tokenAddress][assetId], "LibCollateral: Asset not collateral");
        collateralStorageData.isNonfungibleCollateral[account][tokenAddress][assetId] = false;
    }

    /**
     * @dev Remove fungible collateral for an account
     * @param account The account address
     * @param tokenAddress The address of the token contract
     * @param amount The amount to remove
     */
    function removeFungibleCollateral(
        address account,
        address tokenAddress,
        uint256 amount
    ) internal {
        CollateralStorageData storage collateralStorageData = collateralStorage();
        require(collateralStorageData.fungibleCollateral[account][tokenAddress] >= amount, "LibCollateral: Insufficient fungible collateral");
        collateralStorageData.fungibleCollateral[account][tokenAddress] -= amount;
    }

    /**
     * @dev Remove total collateral for an account
     * @param account The account address
     * @param tokenAddress The address of the token contract
     */
    function removeTotalCollateral(
        address account,
        address tokenAddress
    ) internal {
        CollateralStorageData storage collateralStorageData = collateralStorage();
        require(collateralStorageData.isTotalCollateral[account][tokenAddress], "LibCollateral: Token not total collateral");
        collateralStorageData.isTotalCollateral[account][tokenAddress] = false;
    }

    /**
     * @dev Get nonfungible collateral status for an account
     * @param account The account address
     * @param tokenAddress The address of the token contract
     * @param assetId The asset ID (tokenId for ERC721)
     * @return bool True if the asset is collateral
     */
    function getNonfungibleCollateral(
        address account,
        address tokenAddress,
        uint256 assetId
    ) internal view returns (bool) {
        CollateralStorageData storage collateralStorageData = collateralStorage();
        return collateralStorageData.isNonfungibleCollateral[account][tokenAddress][assetId];
    }

    /**
     * @dev Get fungible collateral amount for an account
     * @param account The account address
     * @param tokenAddress The address of the token contract
     * @return uint256 The amount of fungible collateral
     */
    function getFungibleCollateral(
        address account,
        address tokenAddress
    ) internal view returns (uint256) {
        CollateralStorageData storage collateralStorageData = collateralStorage();
        return collateralStorageData.fungibleCollateral[account][tokenAddress];
    }

    /**
     * @dev Get total collateral status for an account
     * @param account The account address
     * @param tokenAddress The address of the token contract
     * @return bool True if the token is total collateral
     */
    function getTotalCollateral(
        address account,
        address tokenAddress
    ) internal view returns (bool) {
        CollateralStorageData storage collateralStorageData = collateralStorage();
        return collateralStorageData.isTotalCollateral[account][tokenAddress];
    }
}
