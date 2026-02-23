// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;


/**
 * @title UserRewardsConfig
 * @dev Diamond facet for managing user claiming config on a per user basis
 */
library UserRewardsConfig {
    enum RewardsOption {
        PayBalance,
        IncreaseCollateral,
        PayToRecipient,
        InvestToVault,
        PayDebt
    }

    struct DistributionEntry {
        RewardsOption option;
        uint256 percentage;    // % of post-fees amount (0-100)
        address outputToken;   // For PayToRecipient: desired token (address(0) = rewardsToken)
        address target;        // PayToRecipient: recipient. PayDebt: portfolio. InvestToVault: vault. (address(0) = defaults)
    }

    struct UserRewardsConfigData {
        address rewardsToken;
        address recipient;
        address vaultForInvesting;
        // Zero balance distribution
        DistributionEntry[4] zeroBalanceDistribution;
        uint8 zeroBalanceDistributionCount;    // 0-4 active entries
        // Active balance distribution (single entry)
        DistributionEntry activeBalanceDistribution;
        bool hasActiveBalanceDistribution;
    }

    function _getUserRewardsConfigData() internal pure returns (UserRewardsConfigData storage data) {
        bytes32 position = keccak256("storage.UserRewardsConfig");
        assembly {
            data.slot := position
        }
    }

    function setRewardsToken(address rewardsToken) external {
        UserRewardsConfigData storage data = _getUserRewardsConfigData();
        data.rewardsToken = rewardsToken;
    }

    function getRewardsToken() external view returns (address) {
        UserRewardsConfigData storage data = _getUserRewardsConfigData();
        return data.rewardsToken;
    }

    function setRecipient(address recipient) external {
        UserRewardsConfigData storage data = _getUserRewardsConfigData();
        data.recipient = recipient;
    }

    function getRecipient() external view returns (address) {
        UserRewardsConfigData storage data = _getUserRewardsConfigData();
        return data.recipient;
    }

    function setVaultForInvesting(address vault) external {
        UserRewardsConfigData storage data = _getUserRewardsConfigData();
        data.vaultForInvesting = vault;
    }

    function getVaultForInvesting() external view returns (address) {
        UserRewardsConfigData storage data = _getUserRewardsConfigData();
        return data.vaultForInvesting;
    }

    function setZeroBalanceDistribution(DistributionEntry[] calldata entries) external {
        UserRewardsConfigData storage data = _getUserRewardsConfigData();
        require(entries.length <= 4, "Max 4 distribution entries");
        // Clear old entries before setting new ones
        for (uint8 i = 0; i < data.zeroBalanceDistributionCount; i++) {
            delete data.zeroBalanceDistribution[i];
        }
        uint256 totalPercentage;
        for (uint256 i = 0; i < entries.length; i++) {
            require(entries[i].percentage >= 20, "Entry percentage must be >= 20");
            totalPercentage += entries[i].percentage;
            data.zeroBalanceDistribution[i] = entries[i];
        }
        require(totalPercentage <= 100, "Total percentage exceeds 100%");
        data.zeroBalanceDistributionCount = uint8(entries.length);
    }

    function getZeroBalanceDistributionEntry(uint8 index) external view returns (DistributionEntry memory) {
        UserRewardsConfigData storage data = _getUserRewardsConfigData();
        require(index < data.zeroBalanceDistributionCount, "Index out of bounds");
        return data.zeroBalanceDistribution[index];
    }

    function getZeroBalanceDistributionCount() external view returns (uint8) {
        UserRewardsConfigData storage data = _getUserRewardsConfigData();
        return data.zeroBalanceDistributionCount;
    }

    function clearZeroBalanceDistribution() external {
        UserRewardsConfigData storage data = _getUserRewardsConfigData();
        for (uint8 i = 0; i < data.zeroBalanceDistributionCount; i++) {
            delete data.zeroBalanceDistribution[i];
        }
        data.zeroBalanceDistributionCount = 0;
    }

    function setActiveBalanceDistribution(DistributionEntry calldata entry) external {
        UserRewardsConfigData storage data = _getUserRewardsConfigData();
        require(entry.percentage > 0, "Entry percentage must be > 0");
        require(entry.percentage <= 25, "Percentage exceeds 25%");
        data.activeBalanceDistribution = entry;
        data.hasActiveBalanceDistribution = true;
    }

    function getActiveBalanceDistribution() external view returns (DistributionEntry memory) {
        UserRewardsConfigData storage data = _getUserRewardsConfigData();
        return data.activeBalanceDistribution;
    }

    function hasActiveBalanceDistribution() external view returns (bool) {
        UserRewardsConfigData storage data = _getUserRewardsConfigData();
        return data.hasActiveBalanceDistribution;
    }

    function clearActiveBalanceDistribution() external {
        UserRewardsConfigData storage data = _getUserRewardsConfigData();
        delete data.activeBalanceDistribution;
        data.hasActiveBalanceDistribution = false;
    }
}
