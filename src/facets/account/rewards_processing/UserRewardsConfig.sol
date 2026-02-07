// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import { LoanUtils } from "../../../LoanUtils.sol";
import {LoanConfig} from "../config/LoanConfig.sol";

import {ILoan} from "../../../interfaces/ILoan.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {ProtocolTimeLibrary} from "../../../libraries/ProtocolTimeLibrary.sol";

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

    struct UserRewardsConfigData {
        address rewardsToken;
        address recipient;
        RewardsOption rewardsOption;
        uint256 rewardsOptionPercentage;
    }

    function _getUserRewardsConfigData() internal pure returns (UserRewardsConfigData storage collateralManagerData) {
        bytes32 position = keccak256("storage.UserRewardsConfig");
        assembly {
            collateralManagerData.slot := position
        }
    }

    function setRewardsOption(RewardsOption rewardsOption) external {
        UserRewardsConfigData storage collateralManagerData = _getUserRewardsConfigData();
        collateralManagerData.rewardsOption = rewardsOption;
    }

    function setRewardsOptionPercentage(uint256 rewardsOptionPercentage) external {
        UserRewardsConfigData storage collateralManagerData = _getUserRewardsConfigData();
        collateralManagerData.rewardsOptionPercentage = rewardsOptionPercentage;
    }

    function getRewardsOption() external view returns (RewardsOption) {
        UserRewardsConfigData storage collateralManagerData = _getUserRewardsConfigData();
        return collateralManagerData.rewardsOption;
    }

    function getRewardsOptionPercentage() external view returns (uint256) {
        UserRewardsConfigData storage collateralManagerData = _getUserRewardsConfigData();
        return collateralManagerData.rewardsOptionPercentage;
    }

    function setRewardsToken(address rewardsToken) external {
        UserRewardsConfigData storage collateralManagerData = _getUserRewardsConfigData();
        collateralManagerData.rewardsToken = rewardsToken;
    }

    function getRewardsToken() external view returns (address) {
        UserRewardsConfigData storage collateralManagerData = _getUserRewardsConfigData();
        return collateralManagerData.rewardsToken;
    }

    function setRecipient(address recipient) external {
        UserRewardsConfigData storage collateralManagerData = _getUserRewardsConfigData();
        collateralManagerData.recipient = recipient;
    }

    function getRecipient() external view returns (address) {
        UserRewardsConfigData storage collateralManagerData = _getUserRewardsConfigData();
        return collateralManagerData.recipient;
    }
}
