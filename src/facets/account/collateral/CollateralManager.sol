// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import { LoanUtils } from "../../../LoanUtils.sol";
import {AccountConfigStorage} from "../../../storage/AccountConfigStorage.sol";
import {ILoan} from "../../../interfaces/ILoan.sol";

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

    function addLockedColleratal(uint256 tokenId, uint256 amount) external {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedColleratal = collateralManagerData.lockedCollaterals[tokenId];
        // if the token is already accounted for, return early
        if(previousLockedColleratal != 0) {
            return;
        }
        int128 newLockedColleratalInt = IVotingEscrow(address(this)).locked(tokenId).amount;
        uint256 newLockedColleratal = uint256(uint128(newLockedColleratalInt));

        collateralManagerData.lockedCollaterals[tokenId] = newLockedColleratal;
        collateralManagerData.totalLockedColleratal += newLockedColleratal;
    }


    function removeLockedColleratal(uint256 tokenId, address accountConfigStorage) external {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedColleratal = collateralManagerData.lockedCollaterals[tokenId];
        // if the token is not accounted for, return early
        if(previousLockedColleratal == 0) {
            return;
        }
        collateralManagerData.totalLockedColleratal -= previousLockedColleratal;
        collateralManagerData.lockedCollaterals[tokenId] = 0;
        enforceCollateral(accountConfigStorage);
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

    function increaseTotalDebt(uint256 amount) internal {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        collateralManagerData.debt += amount;
    }

    function decreaseTotalDebt(uint256 amount) internal {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        collateralManagerData.debt -= amount;
    }

    function enforceCollateral(address accountConfigStorage) internal view {
        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(accountConfigStorage);
        uint256 totalDebt = getTotalDebt();
        if(totalDebt > maxLoanIgnoreSupply) {
            revert InsufficientCollateral();
        }
    }

    function getMaxLoan(address accountConfigStorage) internal view returns (uint256, uint256) {
        uint256 totalLockedColleratal = getTotalLockedColleratal();
        address loanContract = AccountConfigStorage(accountConfigStorage).getLoanContract();
        uint256 rewardsRate = ILoan(loanContract).getRewardsRate();
        uint256 multiplier = ILoan(loanContract).getMultiplier();
        return LoanUtils.getMaxLoanByRewardsRate(totalLockedColleratal, rewardsRate, multiplier, 0, 0, 0);
    }
}
