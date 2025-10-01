// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PortfolioFactory} from "../accounts/PortfolioFactory.sol";


// Use library


/**
 * @title CollateralStorage
 * @dev Upgradable storage contract for NFT data that can be shared across all users
 * Focuses on ERC721 NFTs with loan contract registration
 */
contract CollateralStorage is Ownable {

    // Storage for NFT data
    struct NonfungibleAsset {
        address tokenAddress;
        uint256 assetId; // Generic identifier for ERC721 
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

    // Named storage slot for account data
    bytes32 private constant ACCOUNT_STORAGE_POSITION = keccak256("storage.CollateralStorage");


    // Modifiers
    modifier onlyPortfolioAccount() {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        require(collateralStorage.portfolioFactory.isUserAccount(msg.sender));
        _;
    }

    constructor(address _portfolioFactory) Ownable(msg.sender) {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        collateralStorage.portfolioFactory = PortfolioFactory(_portfolioFactory);
    }

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
    ) external onlyPortfolioAccount {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        require(!collateralStorage.isNonfungibleCollateral[msg.sender][tokenAddress][assetId]);
        collateralStorage.isNonfungibleCollateral[msg.sender][tokenAddress][assetId] = true;
    }

    function addFungibleCollateral(
        address tokenAddress,
        uint256 amount
    ) external onlyPortfolioAccount {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        collateralStorage.fungibleCollateral[msg.sender][tokenAddress] += amount;
    }

    function addTotalCollateral(
        address tokenAddress
    ) external onlyPortfolioAccount {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        require(!collateralStorage.isTotalCollateral[msg.sender][tokenAddress]);
        collateralStorage.isTotalCollateral[msg.sender][tokenAddress] = true;
    }

    function removeNonfungibleCollateral(
        address tokenAddress,
        uint256 assetId
    ) external onlyPortfolioAccount {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        require(collateralStorage.isNonfungibleCollateral[msg.sender][tokenAddress][assetId]);
        collateralStorage.isNonfungibleCollateral[msg.sender][tokenAddress][assetId] = false;
    }

    function removeFungibleCollateral(
        address tokenAddress,
        uint256 amount
    ) external onlyPortfolioAccount {
        CollateralStorageData storage collateralStorage = _getCollateralStorage();
        require(collateralStorage.fungibleCollateral[msg.sender][tokenAddress] >= amount);
        collateralStorage.fungibleCollateral[msg.sender][tokenAddress] -= amount;
    }

    function removeTotalCollateral(
        address tokenAddress
    ) external onlyPortfolioAccount {
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