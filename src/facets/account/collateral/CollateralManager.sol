// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import { LoanUtils } from "../../../LoanUtils.sol";
import {LoanConfig} from "../config/LoanConfig.sol";

import {ILoan} from "../../../interfaces/ILoan.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
/**
 * @title CollateralManager
 * @dev Diamond facet for managing collateral storage
 * Handles nonfungible, fungible, and total collateral management
 */
library CollateralManager {
    error InsufficientCollateral();
    error InvalidLockedColleratal();


    struct CollateralManagerData {
        mapping(uint256 tokenId => uint256 lockedColleratal) lockedCollaterals;
        uint256 totalLockedColleratal;
        uint256 debt;
    }

    function _getCollateralManagerData() internal pure returns (CollateralManagerData storage collateralManagerData) {
        bytes32 position = keccak256("storage.CollateralManager");
        assembly {
            collateralManagerData.slot := position
        }
    }

    function addLockedColleratal(uint256 tokenId, address ve) external {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedColleratal = collateralManagerData.lockedCollaterals[tokenId];
        // if the token is already accounted for, return early
        if(previousLockedColleratal != 0) {
            return;
        }
        int128 newLockedColleratalInt = IVotingEscrow(address(ve)).locked(tokenId).amount;
        uint256 newLockedColleratal = uint256(uint128(newLockedColleratalInt));

        collateralManagerData.lockedCollaterals[tokenId] = newLockedColleratal;
        collateralManagerData.totalLockedColleratal += newLockedColleratal;
    }


    function removeLockedColleratal(uint256 tokenId, address portfolioAccountConfig) external {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedColleratal = collateralManagerData.lockedCollaterals[tokenId];
        // if the token is not accounted for, return early
        if(previousLockedColleratal == 0) {
            return;
        }
        collateralManagerData.totalLockedColleratal -= previousLockedColleratal;
        collateralManagerData.lockedCollaterals[tokenId] = 0;
        enforceCollateral(portfolioAccountConfig);
    }

    function updateLockedColleratal(uint256 tokenId) external {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedColleratal = collateralManagerData.lockedCollaterals[tokenId];

        // only update collateral for tokens that are already collateralized
        if(previousLockedColleratal == 0) {
            return;
        }

        int128 newLockedColleratalInt = IVotingEscrow(address(this)).locked(tokenId).amount;
        uint256 newLockedColleratal = uint256(uint128(newLockedColleratalInt));
        if(newLockedColleratal > previousLockedColleratal) {
            uint256 difference = newLockedColleratal - previousLockedColleratal;
            collateralManagerData.totalLockedColleratal += difference;
        } else {
            uint256 difference = previousLockedColleratal - newLockedColleratal;
            collateralManagerData.totalLockedColleratal -= difference;
        }

        collateralManagerData.lockedCollaterals[tokenId] = newLockedColleratal;
    }

    function getTotalLockedColleratal() public view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.totalLockedColleratal;
    }

    function getTotalDebt() public view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.debt;
    }

    function increaseTotalDebt(address portfolioAccountConfig, uint256 amount) external {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        collateralManagerData.debt += amount;
        enforceCollateral(portfolioAccountConfig);
    }

    function decreaseTotalDebt(uint256 amount) external {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        collateralManagerData.debt -= amount;
    }

    function enforceCollateral(address portfolioAccountConfig) internal view {
        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        uint256 totalDebt = getTotalDebt();
        // TODO: if voted on but not claimed, then do not allow withdrawals
        if(totalDebt > maxLoanIgnoreSupply) {
            revert InsufficientCollateral();
        }
    }

    function getMaxLoan(address portfolioAccountConfig) internal view returns (uint256, uint256) {
        uint256 totalLockedColleratal = getTotalLockedColleratal();
        LoanConfig loanConfig = PortfolioAccountConfig(portfolioAccountConfig).getLoanConfig();
        uint256 rewardsRate = loanConfig.getRewardsRate();
        uint256 multiplier = loanConfig.getMultiplier();
        return LoanUtils.getMaxLoanByRewardsRate(totalLockedColleratal, rewardsRate, multiplier, 0, 0, 0);
    }
}
