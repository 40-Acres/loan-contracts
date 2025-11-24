// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "../../interfaces/ICollateralFacet.sol";
import "../../libraries/LibCollateral.sol";
import "../../libraries/LibDiamond.sol";

/**
 * @title CollateralFacet
 * @dev Diamond facet for managing collateral storage
 * Handles nonfungible, fungible, and total collateral management
 */
contract CollateralFacet is ICollateralFacet {

    /**
     * @dev Add nonfungible collateral for an account
     * @param tokenAddress The address of the token contract
     * @param assetId The asset ID (tokenId for ERC721)
     */
    function addNonfungibleCollateral(
        address tokenAddress,
        uint256 assetId
    ) external override {
        LibCollateral.enforceIsPortfolioAccount();
        LibCollateral.addNonfungibleCollateral(msg.sender, tokenAddress, assetId);
    }

    /**
     * @dev Add fungible collateral for an account
     * @param tokenAddress The address of the token contract
     * @param amount The amount to add
     */
    function addFungibleCollateral(
        address tokenAddress,
        uint256 amount
    ) external override {
        LibCollateral.enforceIsPortfolioAccount();
        LibCollateral.addFungibleCollateral(msg.sender, tokenAddress, amount);
    }

    /**
     * @dev Add total collateral for an account
     * @param tokenAddress The address of the token contract
     */
    function addTotalCollateral(
        address tokenAddress
    ) external override {
        LibCollateral.enforceIsPortfolioAccount();
        LibCollateral.addTotalCollateral(msg.sender, tokenAddress);
    }

    /**
     * @dev Remove nonfungible collateral for an account
     * @param tokenAddress The address of the token contract
     * @param assetId The asset ID (tokenId for ERC721)
     */
    function removeNonfungibleCollateral(
        address tokenAddress,
        uint256 assetId
    ) external override {
        LibCollateral.enforceIsPortfolioAccount();
        LibCollateral.removeNonfungibleCollateral(msg.sender, tokenAddress, assetId);
    }

    /**
     * @dev Remove fungible collateral for an account
     * @param tokenAddress The address of the token contract
     * @param amount The amount to remove
     */
    function removeFungibleCollateral(
        address tokenAddress,
        uint256 amount
    ) external override {
        LibCollateral.enforceIsPortfolioAccount();
        LibCollateral.removeFungibleCollateral(msg.sender, tokenAddress, amount);
    }

    /**
     * @dev Remove total collateral for an account
     * @param tokenAddress The address of the token contract
     */
    function removeTotalCollateral(
        address tokenAddress
    ) external override {
        LibCollateral.enforceIsPortfolioAccount();
        LibCollateral.removeTotalCollateral(msg.sender, tokenAddress);
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
    ) external view override returns (bool) {
        return LibCollateral.getNonfungibleCollateral(account, tokenAddress, assetId);
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
    ) external view override returns (uint256) {
        return LibCollateral.getFungibleCollateral(account, tokenAddress);
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
    ) external view override returns (bool) {
        return LibCollateral.getTotalCollateral(account, tokenAddress);
    }

    /**
     * @dev Initialize the collateral storage with portfolio factory
     * @param portfolioFactory The portfolio factory address
     */
    function initCollateralStorage(address portfolioFactory) external override {
        LibDiamond.enforceIsContractOwner();
        LibCollateral.initCollateralStorage(portfolioFactory);
    }
}
