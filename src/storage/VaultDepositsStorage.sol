// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title VaultDepositsStorage
 * @dev Storage for tracking ERC4626 vault share deposits and their original asset values
 */
library VaultDepositsStorage {
    struct VaultDeposit {
        uint256 shares;           // Total shares deposited
        uint256 depositedAssets;  // Total assets value at time of deposit
    }

    struct VaultDepositsData {
        // vault address => deposit info
        mapping(address => VaultDeposit) deposits;
    }

    bytes32 private constant STORAGE_POSITION = keccak256("storage.VaultDepositsStorage");

    function _getStorage() internal pure returns (VaultDepositsData storage data) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            data.slot := position
        }
    }

    function addDeposit(address vault, uint256 shares, uint256 assets) external {
        VaultDepositsData storage data = _getStorage();
        data.deposits[vault].shares += shares;
        data.deposits[vault].depositedAssets += assets;
    }

    function removeDeposit(address vault, uint256 shares, uint256 assets) external {
        VaultDepositsData storage data = _getStorage();
        require(data.deposits[vault].shares >= shares, "Insufficient shares");
        require(data.deposits[vault].depositedAssets >= assets, "Insufficient deposited assets");
        data.deposits[vault].shares -= shares;
        data.deposits[vault].depositedAssets -= assets;
    }

    function getDeposit(address vault) external view returns (uint256 shares, uint256 depositedAssets) {
        VaultDepositsData storage data = _getStorage();
        return (data.deposits[vault].shares, data.deposits[vault].depositedAssets);
    }

    function getShares(address vault) external view returns (uint256) {
        VaultDepositsData storage data = _getStorage();
        return data.deposits[vault].shares;
    }

    function getDepositedAssets(address vault) external view returns (uint256) {
        VaultDepositsData storage data = _getStorage();
        return data.deposits[vault].depositedAssets;
    }
}
