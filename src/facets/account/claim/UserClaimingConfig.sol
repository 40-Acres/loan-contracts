// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import { LoanUtils } from "../../../LoanUtils.sol";
import {LoanConfig} from "../config/LoanConfig.sol";

import {ILoan} from "../../../interfaces/ILoan.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {ProtocolTimeLibrary} from "../../../libraries/ProtocolTimeLibrary.sol";
/**
 * @title UserClaimingConfig
 * @dev Diamond facet for managing user claiming config on a per user basis
 */
library UserClaimingConfig {
    error InsufficientCollateral();
    error InvalidLockedCollateral();


    struct UserClaimingConfigData {
        mapping(uint256 epoch => mapping (uint256 tokenId => bool)) tokenIdClaimed; // whether user has claimed tokens for the epoch
        mapping(uint256 epoch => mapping (uint256 tokenId => address launchpadToken)) epochLaunchpadToken; // the epoch that user will receive launchpad token
        mapping(uint256 epoch => bool) receiveLaunchPadToken; // whether user wants to receive launchpad token directly or swap it
    }

    function _getUserClaimingConfigData() internal pure returns (UserClaimingConfigData storage collateralManagerData) {
        bytes32 position = keccak256("storage.UserClaimingConfig");
        assembly {
            collateralManagerData.slot := position
        }
    }

    function setClaimed(uint256 epoch, uint256 tokenId,bool claimed) external {
        UserClaimingConfigData storage collateralManagerData = _getUserClaimingConfigData();
        collateralManagerData.tokenIdClaimed[epoch][tokenId] = claimed;
    }

    function getClaimed(uint256 epoch, uint256 tokenId) external view returns (bool) {
        UserClaimingConfigData storage collateralManagerData = _getUserClaimingConfigData();
        return collateralManagerData.tokenIdClaimed[ProtocolTimeLibrary.epochStart(epoch)][tokenId];
    }

    function isTokenClaimedForCurrentEpoch(uint256 tokenId) external view returns (bool) {
        UserClaimingConfigData storage collateralManagerData = _getUserClaimingConfigData();
        return collateralManagerData.tokenIdClaimed[ProtocolTimeLibrary.epochStart(block.timestamp)][tokenId];
    }

    function getLaunchPadTokenForEpoch(uint256 epoch, uint256 tokenId) external view returns (address) {
        UserClaimingConfigData storage collateralManagerData = _getUserClaimingConfigData();
        return collateralManagerData.epochLaunchpadToken[epoch][tokenId];
    }

    function setLaunchPadTokenForNextEpoch(uint256 tokenId, address launchpadToken) external {
        UserClaimingConfigData storage collateralManagerData = _getUserClaimingConfigData();
        collateralManagerData.epochLaunchpadToken[ProtocolTimeLibrary.epochNext(block.timestamp)][tokenId] = launchpadToken;
    }

    function getLaunchPadTokenForCurrentEpoch(uint256 tokenId) external view returns (address) {
        UserClaimingConfigData storage collateralManagerData = _getUserClaimingConfigData();
        return collateralManagerData.epochLaunchpadToken[ProtocolTimeLibrary.epochStart(block.timestamp)][tokenId];
    }

    function setReceiveLaunchPadTokenForNextEpoch(bool receiveLaunchPadToken) external {
        UserClaimingConfigData storage collateralManagerData = _getUserClaimingConfigData();
        collateralManagerData.receiveLaunchPadToken[ProtocolTimeLibrary.epochNext(block.timestamp)] = receiveLaunchPadToken;
    }

    function getReceiveLaunchPadTokenForThisEpoch() external view returns (bool) {
        UserClaimingConfigData storage collateralManagerData = _getUserClaimingConfigData();
        return collateralManagerData.receiveLaunchPadToken[ProtocolTimeLibrary.epochStart(block.timestamp)];
    }
}
