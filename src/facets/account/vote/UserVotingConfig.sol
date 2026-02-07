// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import { LoanUtils } from "../../../LoanUtils.sol";
import {LoanConfig} from "../config/LoanConfig.sol";

import {ILoan} from "../../../interfaces/ILoan.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {ProtocolTimeLibrary} from "../../../libraries/ProtocolTimeLibrary.sol";
/**
 * @title UserVotingConfig
 * @dev Diamond facet for managing user claiming config on a per user basis
 */
library UserVotingConfig {

    struct UserVotingConfigData {
        mapping(uint256 tokenId => bool isManualVoting) isManualVoting;
        mapping(uint256 tokenId => address delegatedVoter) delegatedVoter;
    }

    function _getUserVotingConfigData() internal pure returns (UserVotingConfigData storage collateralManagerData) {
        bytes32 position = keccak256("storage.UserVotingConfig");
        assembly {
            collateralManagerData.slot := position
        }
    }

    function setVotingMode(uint256 tokenId, bool setToManualVoting) external {
        UserVotingConfigData storage collateralManagerData = _getUserVotingConfigData();
        collateralManagerData.isManualVoting[tokenId] = setToManualVoting;
    }

    function isManualVoting(uint256 tokenId) external view returns (bool) {
        UserVotingConfigData storage userVotingConfigData = _getUserVotingConfigData();
        return userVotingConfigData.isManualVoting[tokenId];
    }

    function setDelegatedVoter(uint256 tokenId, address delegatedVoter) external {
        UserVotingConfigData storage collateralManagerData = _getUserVotingConfigData();
        collateralManagerData.delegatedVoter[tokenId] = delegatedVoter;
    }

    function getDelegatedVoter(uint256 tokenId) external view returns (address) {
        UserVotingConfigData storage collateralManagerData = _getUserVotingConfigData();
        return collateralManagerData.delegatedVoter[tokenId];
    }
}
