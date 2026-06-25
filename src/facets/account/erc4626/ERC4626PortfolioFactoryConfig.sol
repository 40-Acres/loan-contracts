// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactoryConfig} from "../config/PortfolioFactoryConfig.sol";

/// @dev Minimal probe interface: managers try/catch this so base configs (no such function) skip enforcement.
interface IERC4626CollateralVaultConfig {
    function getCollateralVault() external view returns (address);
}

/**
 * @title ERC4626PortfolioFactoryConfig
 * @dev Extends PortfolioFactoryConfig with the canonical ERC4626 collateral vault
 *      for this market. The ERC4626 collateral managers read getCollateralVault()
 *      and revert if a facet ever presents a different vault, so a re-cut to a
 *      different vault cannot silently reinterpret existing account storage. The
 *      vault is written once at market setup and cannot be repointed.
 */
contract ERC4626PortfolioFactoryConfig is PortfolioFactoryConfig {
    struct ERC4626ConfigData {
        address collateralVault;
    }

    bytes32 private constant ERC4626_CONFIG_STORAGE_POSITION = keccak256("storage.ERC4626PortfolioFactoryConfig");

    event CollateralVaultSet(address vault);

    error CollateralVaultAlreadySet(address current);
    error ZeroCollateralVault();

    function _getErc4626Config() internal pure returns (ERC4626ConfigData storage data) {
        bytes32 position = ERC4626_CONFIG_STORAGE_POSITION;
        assembly {
            data.slot := position
        }
    }

    /// @dev Set-once: the collateral vault is fixed for the lifetime of the market.
    function setCollateralVault(address vault) external onlyOwner {
        if (vault == address(0)) revert ZeroCollateralVault();
        ERC4626ConfigData storage data = _getErc4626Config();
        if (data.collateralVault != address(0)) revert CollateralVaultAlreadySet(data.collateralVault);
        data.collateralVault = vault;
        emit CollateralVaultSet(vault);
    }

    /// @dev Returns address(0) until set; managers treat unset as "not yet enforced".
    function getCollateralVault() external view returns (address) {
        return _getErc4626Config().collateralVault;
    }
}
