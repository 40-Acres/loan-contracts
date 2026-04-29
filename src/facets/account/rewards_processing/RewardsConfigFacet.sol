// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioFactoryConfig} from "../config/PortfolioFactoryConfig.sol";
import {UserRewardsConfig} from "./UserRewardsConfig.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {IPortfolioManager} from "../../../accounts/IPortfolioManager.sol";

/**
 * @title RewardsConfigFacet
 * @dev Facet that manages rewards configuration for a portfolio account.
 *      Split from RewardsProcessingFacet to reduce contract size.
 */
contract RewardsConfigFacet is AccessControl {
    PortfolioFactory public immutable _portfolioFactory;

    event RecipientSet(address recipient, address indexed owner);
    event VaultForInvestingSet(address vault, address indexed owner);
    event ZeroBalanceDistributionSet(uint256 entryCount, address indexed owner);
    event ZeroBalanceDistributionCleared(address indexed owner);
    event ActiveBalanceDistributionSet(uint256 entryCount, address indexed owner);
    event ActiveBalanceDistributionCleared(address indexed owner);

    constructor(address portfolioFactory) {
        require(portfolioFactory != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
    }

    function setRecipient(address recipient) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.setRecipient(recipient);
        address owner = _portfolioFactory.ownerOf(address(this));
        emit RecipientSet(recipient, owner);
    }

    function setVaultForInvesting(address vault) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.setVaultForInvesting(vault);
        emit VaultForInvestingSet(vault, _portfolioFactory.ownerOf(address(this)));
    }

    function getVaultForInvesting() external view returns (address) {
        return UserRewardsConfig.getVaultForInvesting();
    }

    function setZeroBalanceDistribution(
        UserRewardsConfig.DistributionEntry[] calldata entries
    ) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        IPortfolioManager portfolioManager = IPortfolioManager(address(_portfolioFactory.portfolioManager()));
        address thisOwner = _portfolioFactory.ownerOf(address(this));
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].option == UserRewardsConfig.RewardsOption.PayDebt && entries[i].target != address(0)) {
                require(portfolioManager.isRegisteredFactory(entries[i].target), "PayDebt target must be registered factory");
                address targetPortfolio = PortfolioFactory(entries[i].target).portfolioOf(thisOwner);
                require(targetPortfolio != address(0), "PayDebt target factory must have portfolio for owner");
            }
        }
        UserRewardsConfig.setZeroBalanceDistribution(entries);
        emit ZeroBalanceDistributionSet(entries.length, _portfolioFactory.ownerOf(address(this)));
    }

    function getZeroBalanceDistribution() external view returns (UserRewardsConfig.DistributionEntry[] memory) {
        uint8 count = UserRewardsConfig.getZeroBalanceDistributionCount();
        UserRewardsConfig.DistributionEntry[] memory entries = new UserRewardsConfig.DistributionEntry[](count);
        for (uint8 i = 0; i < count; i++) {
            entries[i] = UserRewardsConfig.getZeroBalanceDistributionEntry(i);
        }
        return entries;
    }

    function clearZeroBalanceDistribution() external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.clearZeroBalanceDistribution();
        emit ZeroBalanceDistributionCleared(_portfolioFactory.ownerOf(address(this)));
    }

    function setActiveBalanceDistribution(
        UserRewardsConfig.DistributionEntry calldata entry
    ) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        if (entry.option == UserRewardsConfig.RewardsOption.PayDebt && entry.target != address(0)) {
            IPortfolioManager portfolioManager = IPortfolioManager(address(_portfolioFactory.portfolioManager()));
            address thisOwner = _portfolioFactory.ownerOf(address(this));
            require(portfolioManager.isRegisteredFactory(entry.target), "PayDebt target must be registered factory");
            address targetPortfolio = PortfolioFactory(entry.target).portfolioOf(thisOwner);
            require(targetPortfolio != address(0), "PayDebt target factory must have portfolio for owner");
        }
        UserRewardsConfig.setActiveBalanceDistribution(entry);
        emit ActiveBalanceDistributionSet(1, _portfolioFactory.ownerOf(address(this)));
    }

    function getActiveBalanceDistribution() external view returns (UserRewardsConfig.DistributionEntry memory) {
        return UserRewardsConfig.getActiveBalanceDistribution();
    }

    function clearActiveBalanceDistribution() external onlyPortfolioManagerMulticall(_portfolioFactory) {
        UserRewardsConfig.clearActiveBalanceDistribution();
        emit ActiveBalanceDistributionCleared(_portfolioFactory.ownerOf(address(this)));
    }
}
