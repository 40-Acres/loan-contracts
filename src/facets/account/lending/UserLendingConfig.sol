// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import { LoanUtils } from "../../../LoanUtils.sol";
import {LoanConfig} from "../config/LoanConfig.sol";

import {ILoan} from "../../../interfaces/ILoan.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {ProtocolTimeLibrary} from "../../../libraries/ProtocolTimeLibrary.sol";

/**
 * @title UserLendingConfig
 * @dev Diamond facet for managing user claiming config on a per user basis
 */
library UserLendingConfig {

    struct UserLendingConfigData {
        bool topUpEnabled;
    }

    function _getUserLendingConfigData() internal pure returns (UserLendingConfigData storage collateralManagerData) {
        bytes32 position = keccak256("storage.UserLendingConfig");
        assembly {
            collateralManagerData.slot := position
        }
    }


    function setTopUp(bool topUpEnabled) external {
        UserLendingConfigData storage collateralManagerData = _getUserLendingConfigData();
        collateralManagerData.topUpEnabled = topUpEnabled;
    }

    function getTopUp() external view returns (bool) {
        UserLendingConfigData storage collateralManagerData = _getUserLendingConfigData();
        return collateralManagerData.topUpEnabled;
    }

}
