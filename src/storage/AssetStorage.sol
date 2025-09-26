// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AssetStorage
 * @dev Upgradable storage contract for NFT data that can be shared across all users
 * Focuses on ERC721 NFTs with loan contract registration
 */
contract AssetStorage is Ownable {
    // Events
    event AssetDeposited(address indexed account, address indexed tokenAddress, uint256 assetId, address indexed assetHandler);
    event AssetWithdrawn(address indexed account, address indexed tokenAddress, uint256 assetId);
    event AssetHandlerRegistered(address indexed account, address indexed tokenAddress, uint256 assetId, address indexed assetHandler);
    event StorageUpgraded(address indexed newImplementation, uint256 newVersion);

    // Storage for NFT data
    struct NFTData {
        address tokenAddress;
        uint256 assetId; // Generic identifier for ERC721 (tokenId), ERC1155 (tokenId), ERC20 (0 or unique ID)
        address assetHandler; // Contract that handles this asset's operations (voting, claiming, loans)
        bool isCollateral; // Whether this asset is used as collateral
    }

    // Token storage data using named storage slot
    struct AssetStorageData {
        mapping(address => NFTData[]) nfts;
        mapping(address => uint256) totalNFTs;
        
        // Asset handler tracking
        mapping(address => mapping(address => mapping(uint256 => address))) assetHandlers; // account => token => assetId => assetHandler
        
        // Collateral tracking
        mapping(address => mapping(address => mapping(uint256 => bool))) collateralStatus; // account => token => assetId => isCollateral
    }

    // Version tracking
    uint256 public version;
    
    // Named storage slot for account data
    bytes32 private constant ACCOUNT_STORAGE_POSITION = keccak256("storage.AssetStorage");

    // Access control
    mapping(address => bool) public authorizedCallers;

    // Modifiers
    modifier onlyPortfolioAccount(address _account) {
        // require(authorizedCallers[msg.sender], "AssetStorage: Unauthorized caller");
        _;
    }

    constructor() Ownable(msg.sender) {
        version = 1;
    }

    /**
     * @dev Authorize a caller to interact with storage
     * @param _caller The address to authorize
     */
    function authorizeCaller(address _caller) external onlyOwner {
        require(_caller != address(0), "AssetStorage: Invalid caller");
        authorizedCallers[_caller] = true;
    }

    /**
     * @dev Revoke authorization for a caller
     * @param _caller The address to revoke authorization from
     */
    function revokeCaller(address _caller) external onlyOwner {
        require(_caller != address(0), "AssetStorage: Invalid caller");
        authorizedCallers[_caller] = false;
    }

    /**
     * @dev Get token storage data from named storage slot
     */
    function _getAssetStorage() internal pure returns (AssetStorageData storage assetStorage) {
        bytes32 position = ACCOUNT_STORAGE_POSITION;
        assembly {
            assetStorage.slot := position
        }
    }


    /**
     * @dev Deposit an asset (ERC721, ERC1155, or ERC20)
     * @param account The account depositing the asset
     * @param tokenAddress The address of the token
     * @param assetId The identifier for the asset (ERC721 tokenId, ERC1155 tokenId, ERC20 0 or unique ID)
     * @param assetHandler The asset handler contract for this asset (handles voting, claiming, loans)
     */
    function depositAsset(
        address account, 
        address tokenAddress, 
        uint256 assetId, 
        address assetHandler
    ) external onlyAuthorizedCaller {
        require(account != address(0), "AssetStorage: Invalid account");
        require(tokenAddress != address(0), "AssetStorage: Invalid token address");
        require(assetHandler != address(0), "AssetStorage: Invalid asset handler");
        
        AssetStorageData storage assetStorage = _getAssetStorage();
        
        // Check if asset already exists
        require(!_assetExists(account, tokenAddress, assetId), "AssetStorage: Asset already deposited");
        
        // Create asset data
        NFTData memory assetData = NFTData({
            tokenAddress: tokenAddress,
            assetId: assetId,
            assetHandler: assetHandler,
            isCollateral: false
        });
        
        // Store asset data
        assetStorage.nfts[account].push(assetData);
        assetStorage.totalNFTs[account]++;
        assetStorage.assetHandlers[account][tokenAddress][assetId] = assetHandler;
        
        emit AssetDeposited(account, tokenAddress, assetId, assetHandler);
        emit AssetHandlerRegistered(account, tokenAddress, assetId, assetHandler);
    }

    /**
     * @dev Withdraw an asset
     * @param account The account withdrawing the asset
     * @param tokenAddress The address of the token
     * @param assetId The identifier for the asset
     */
    function withdrawAsset(
        address account, 
        address tokenAddress, 
        uint256 assetId
    ) external onlyAuthorizedCaller {
        require(account != address(0), "AssetStorage: Invalid account");
        require(tokenAddress != address(0), "AssetStorage: Invalid token address");
        
        AssetStorageData storage assetStorage = _getAssetStorage();
        
        // Check if asset exists and is not collateral
        require(_assetExists(account, tokenAddress, assetId), "AssetStorage: Asset not found");
        require(!assetStorage.collateralStatus[account][tokenAddress][assetId], 
                "AssetStorage: Cannot withdraw asset used as collateral");
                
        // Remove asset from storage
        _removeAsset(account, tokenAddress, assetId);
        assetStorage.totalNFTs[account]--;
        delete assetStorage.assetHandlers[account][tokenAddress][assetId];
        
        emit AssetWithdrawn(account, tokenAddress, assetId);
    }

    /**
     * @dev Set asset as collateral
     * @param account The account
     * @param tokenAddress The token address
     * @param assetId The asset identifier
     * @param isCollateral Whether the asset is collateral
     */
    function setAssetCollateral(
        address account,
        address tokenAddress,
        uint256 assetId,
        bool isCollateral
    ) external onlyAuthorizedCaller {
        require(account != address(0), "AssetStorage: Invalid account");
        require(tokenAddress != address(0), "AssetStorage: Invalid token address");
        require(_assetExists(account, tokenAddress, assetId), "AssetStorage: Asset not found");
        
        AssetStorageData storage assetStorage = _getAssetStorage();
        assetStorage.collateralStatus[account][tokenAddress][assetId] = isCollateral;
        
        // Update the asset data
        for (uint256 i = 0; i < assetStorage.nfts[account].length; i++) {
            if (assetStorage.nfts[account][i].tokenAddress == tokenAddress && 
                assetStorage.nfts[account][i].assetId == assetId) {
                assetStorage.nfts[account][i].isCollateral = isCollateral;
                break;
            }
        }
    }

    /**
     * @dev Get asset handler for an asset
     * @param account The account
     * @param tokenAddress The token address
     * @param assetId The asset identifier
     * @return The asset handler address
     */
    function getAssetHandler(
        address account,
        address tokenAddress,
        uint256 assetId
    ) external view returns (address) {
        AssetStorageData storage assetStorage = _getAssetStorage();
        return assetStorage.assetHandlers[account][tokenAddress][assetId];
    }

    /**
     * @dev Check if asset is collateral
     * @param account The account
     * @param tokenAddress The token address
     * @param assetId The asset identifier
     * @return Whether the asset is collateral
     */
    function isAssetCollateral(
        address account,
        address tokenAddress,
        uint256 assetId
    ) external view returns (bool) {
        AssetStorageData storage assetStorage = _getAssetStorage();
        return assetStorage.collateralStatus[account][tokenAddress][assetId];
    }

    /**
     * @dev Get all NFTs for an account
     * @param account The account
     * @return Array of NFT data
     */
    function getAccountNFTs(address account) external view returns (NFTData[] memory) {
        AssetStorageData storage assetStorage = _getAssetStorage();
        return assetStorage.nfts[account];
    }

    /**
     * @dev Get total number of NFTs for an account
     * @param account The account
     * @return Total number of NFTs
     */
    function getTotalNFTs(address account) external view returns (uint256) {
        AssetStorageData storage assetStorage = _getAssetStorage();
        return assetStorage.totalNFTs[account];
    }

    /**
     * @dev Check if asset exists
     * @param account The account
     * @param tokenAddress The token address
     * @param assetId The asset identifier
     * @return Whether the asset exists
     */
    function assetExists(
        address account,
        address tokenAddress,
        uint256 assetId
    ) external view returns (bool) {
        return _assetExists(account, tokenAddress, assetId);
    }

    /**
     * @dev Internal function to check if asset exists
     */
    function _assetExists(
        address account,
        address tokenAddress,
        uint256 assetId
    ) internal view returns (bool) {
        AssetStorageData storage assetStorage = _getAssetStorage();
        return assetStorage.assetHandlers[account][tokenAddress][assetId] != address(0);
    }

    /**
     * @dev Internal function to remove asset from storage
     */
    function _removeAsset(
        address account,
        address tokenAddress,
        uint256 assetId
    ) internal {
        AssetStorageData storage assetStorage = _getAssetStorage();
        
        // Find and remove the asset
        for (uint256 i = 0; i < assetStorage.nfts[account].length; i++) {
            if (assetStorage.nfts[account][i].tokenAddress == tokenAddress && 
                assetStorage.nfts[account][i].assetId == assetId) {
                // Move the last element to the deleted spot
                assetStorage.nfts[account][i] = assetStorage.nfts[account][assetStorage.nfts[account].length - 1];
                assetStorage.nfts[account].pop();
                    break;
                }
            }
            
        // Clean up collateral status
        delete assetStorage.collateralStatus[account][tokenAddress][assetId];
    }

    /**
     * @dev Upgrade storage implementation
     * @param newImplementation The new implementation address
     * @param newVersion The new version number
     */
    function upgradeStorage(address newImplementation, uint256 newVersion) external onlyOwner {
        require(newImplementation != address(0), "AssetStorage: Invalid implementation");
        require(newVersion > version, "AssetStorage: Version must be higher");
        
        version = newVersion;
        
        emit StorageUpgraded(newImplementation, newVersion);
    }

    /**
     * @dev Get current version
     * @return Current version number
     */
    function getVersion() external view returns (uint256) {
        return version;
    }
}