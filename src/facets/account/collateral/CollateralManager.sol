// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import { LoanUtils } from "../../../LoanUtils.sol";
import {LoanConfig} from "../config/LoanConfig.sol";

import {ILoan} from "../../../interfaces/ILoan.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";

import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CollateralManager
 * @dev Diamond facet for managing collateral storage
 * Handles nonfungible, fungible, and total collateral management
 */
library CollateralManager {
    error InsufficientCollateral();
    error InvalidLockedCollateral();


    struct CollateralManagerData {
        mapping(uint256 tokenId => uint256 lockedCollateral) lockedCollaterals;
        mapping(uint256 tokenId => uint256 originTimestamp) originTimestamps;
        uint256 totalLockedCollateral;
        uint256 debt;
    }

    function _getCollateralManagerData() internal pure returns (CollateralManagerData storage collateralManagerData) {
        bytes32 position = keccak256("storage.CollateralManager");
        assembly {
            collateralManagerData.slot := position
        }
    }

    function addLockedCollateral(uint256 tokenId, address ve) external {
        require(ve != address(0), "Voting escrow address cannot be zero");
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedCollateral = collateralManagerData.lockedCollaterals[tokenId];
        // if the token is already accounted for, return early
        if(previousLockedCollateral != 0) {
            return;
        }
        int128 newLockedCollateralInt = IVotingEscrow(address(ve)).locked(tokenId).amount;
        uint256 newLockedCollateral = uint256(uint128(newLockedCollateralInt));

        collateralManagerData.lockedCollaterals[tokenId] = newLockedCollateral;
        collateralManagerData.totalLockedCollateral += newLockedCollateral;
        collateralManagerData.originTimestamps[tokenId] = block.timestamp;
    }


    function removeLockedCollateral(uint256 tokenId, address portfolioAccountConfig) external {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedCollateral = collateralManagerData.lockedCollaterals[tokenId];
        // if the token is not accounted for, return early
        if(previousLockedCollateral == 0) {
            return;
        }
        collateralManagerData.totalLockedCollateral -= previousLockedCollateral;
        collateralManagerData.lockedCollaterals[tokenId] = 0;
        collateralManagerData.originTimestamps[tokenId] = 0;
    }

    function updateLockedCollateral(uint256 tokenId, address ve) external {
        require(ve != address(0), "Voting escrow address cannot be zero");
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedCollateral = collateralManagerData.lockedCollaterals[tokenId];

        // only update collateral for tokens that are already collateralized
        if(previousLockedCollateral == 0) {
            return;
        }

        int128 newLockedCollateralInt = IVotingEscrow(address(ve)).locked(tokenId).amount;
        uint256 newLockedCollateral = uint256(uint128(newLockedCollateralInt));
        if(newLockedCollateral > previousLockedCollateral) {
            uint256 difference = newLockedCollateral - previousLockedCollateral;
            collateralManagerData.totalLockedCollateral += difference;
        } else {
            uint256 difference = previousLockedCollateral - newLockedCollateral;
            collateralManagerData.totalLockedCollateral -= difference;
        }

        collateralManagerData.lockedCollaterals[tokenId] = newLockedCollateral;
    }

    function getTotalLockedCollateral() public view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.totalLockedCollateral;
    }

    function getTotalDebt() public view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.debt;
    }

    function increaseTotalDebt(address portfolioAccountConfig, uint256 amount) external {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        ILoan loanContract = ILoan(PortfolioAccountConfig(portfolioAccountConfig).getLoanContract());

        (uint256 maxLoan, ) = getMaxLoan(portfolioAccountConfig);
        // Revert if no collateral (maxLoan == 0) or amount exceeds maxLoan
        if (maxLoan == 0 || amount > maxLoan) {
            revert InsufficientCollateral();
        }
        // Add the borrowed amount to debt
        collateralManagerData.debt += amount;
        loanContract.borrowFromPortfolio(amount);
    }

    function migrateDebt(address portfolioAccountConfig, uint256 amount) external {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        collateralManagerData.debt += amount;
    }

    function decreaseTotalDebt(address portfolioAccountConfig, uint256 amount) external returns (uint256 excess) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 totalDebt = collateralManagerData.debt;
        uint256 amountToDecrease = totalDebt > amount ? amount : totalDebt;
        collateralManagerData.debt -= amountToDecrease;
        excess = amount - amountToDecrease;
        ILoan loanContract = ILoan(PortfolioAccountConfig(portfolioAccountConfig).getLoanContract());
        loanContract.payFromPortfolio(amountToDecrease);
        return excess;
    }

    function enforceCollateral(address portfolioAccountConfig) public view {
        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        uint256 totalDebt = getTotalDebt();
        // TODO: if voted on but not claimed, then do not allow withdrawals
        if(totalDebt > maxLoanIgnoreSupply) {
            revert InsufficientCollateral();
        }
    }

    function getMaxLoan(address portfolioAccountConfig) public view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        uint256 totalLockedCollateral = getTotalLockedCollateral();
        LoanConfig loanConfig = PortfolioAccountConfig(portfolioAccountConfig).getLoanConfig();
        uint256 rewardsRate = loanConfig.getRewardsRate();
        uint256 multiplier = loanConfig.getMultiplier();

        ILoan loanContract = ILoan(PortfolioAccountConfig(portfolioAccountConfig).getLoanContract());
        uint256 outstandingCapital = loanContract.activeAssets();
        
        address vault = loanContract._vault();
        IERC4626 vaultAsset = IERC4626(vault);
        // Get the underlying asset balance in the vault 
        address underlyingAsset = vaultAsset.asset();
        uint256 vaultBalance = IERC20(underlyingAsset).balanceOf(address(vault));
        
        // Get current total debt for the portfolio account 
        uint256 currentLoanBalance = getTotalDebt();

        return LoanUtils.getMaxLoanByRewardsRate(totalLockedCollateral, rewardsRate, multiplier, vaultBalance, outstandingCapital, currentLoanBalance);
    }

    function getOriginTimestamp(uint256 tokenId) external view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.originTimestamps[tokenId];
    }
}
