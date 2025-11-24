// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title ICollateralFacet
 * @dev Interface for collateral management in diamond pattern
 */
interface ICollateralFacet {
    
    /**
     * @dev Add nonfungible collateral for an account
     * @param tokenAddress The address of the token contract
     * @param assetId The asset ID (tokenId for ERC721)
     */
    function addNonfungibleCollateral(
        address tokenAddress,
        uint256 assetId
    ) external;

    /**
     * @dev Add fungible collateral for an account
     * @param tokenAddress The address of the token contract
     * @param amount The amount to add
     */
    function addFungibleCollateral(
        address tokenAddress,
        uint256 amount
    ) external;

    /**
     * @dev Add total collateral for an account
     * @param tokenAddress The address of the token contract
     */
    function addTotalCollateral(
        address tokenAddress
    ) external;

    /**
     * @dev Remove nonfungible collateral for an account
     * @param tokenAddress The address of the token contract
     * @param assetId The asset ID (tokenId for ERC721)
     */
    function removeNonfungibleCollateral(
        address tokenAddress,
        uint256 assetId
    ) external;

    /**
     * @dev Remove fungible collateral for an account
     * @param tokenAddress The address of the token contract
     * @param amount The amount to remove
     */
    function removeFungibleCollateral(
        address tokenAddress,
        uint256 amount
    ) external;

    /**
     * @dev Remove total collateral for an account
     * @param tokenAddress The address of the token contract
     */
    function removeTotalCollateral(
        address tokenAddress
    ) external;

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
    ) external view returns (bool);

    /**
     * @dev Get fungible collateral amount for an account
     * @param account The account address
     * @param tokenAddress The address of the token contract
     * @return uint256 The amount of fungible collateral
     */
    function getFungibleCollateral(
        address account,
        address tokenAddress
    ) external view returns (uint256);

    /**
     * @dev Get total collateral status for an account
     * @param account The account address
     * @param tokenAddress The address of the token contract
     * @return bool True if the token is total collateral
     */
    function getTotalCollateral(
        address account,
        address tokenAddress
    ) external view returns (bool);

    /**
     * @dev Initialize the collateral storage with portfolio factory
     * @param portfolioFactory The portfolio factory address
     */
    function initCollateralStorage(address portfolioFactory) external;
}
