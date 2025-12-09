// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import { LoanUtils } from "../../../LoanUtils.sol";
import {LoanConfig} from "../config/LoanConfig.sol";

import {ILoan} from "../../../interfaces/ILoan.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";

import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {console} from "forge-std/console.sol";

/**
 * @title CollateralManager
 * @dev Diamond facet for managing collateral storage
 * Handles nonfungible, fungible, and total collateral management
 */
library CollateralManager {
    error InsufficientCollateral();
    error InvalidLockedCollateral();
    error BadDebt(uint256 debt);
    error UndercollateralizedDebt(uint256 debt);

    struct CollateralManagerData {
        mapping(uint256 tokenId => uint256 lockedCollateral) lockedCollaterals;
        mapping(uint256 tokenId => uint256 originTimestamp) originTimestamps;
        uint256 totalLockedCollateral;
        uint256 debt;
        uint256 unpaidFees;
        uint256 badDebt;
        uint256 undercollateralizedDebt;
    }

    function _getCollateralManagerData() internal pure returns (CollateralManagerData storage collateralManagerData) {
        bytes32 position = keccak256("storage.CollateralManager");
        assembly {
            collateralManagerData.slot := position
        }
    }

    function addLockedCollateral(address portfolioAccountConfig, uint256 tokenId, address ve) external {
        require(ve != address(0), "Voting escrow address cannot be zero");
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedCollateral = collateralManagerData.lockedCollaterals[tokenId];
        (, uint256 previousMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        // if the token is already accounted for, return early
        if(previousLockedCollateral != 0) {
            return;
        }
        int128 newLockedCollateralInt = IVotingEscrow(address(ve)).locked(tokenId).amount;
        require(newLockedCollateralInt > 0, "Locked collateral amount must be greater than 0");
        uint256 newLockedCollateral = uint256(uint128(newLockedCollateralInt));

        collateralManagerData.lockedCollaterals[tokenId] = newLockedCollateral;
        collateralManagerData.totalLockedCollateral += newLockedCollateral;
        collateralManagerData.originTimestamps[tokenId] = block.timestamp;


        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        _updateUndercollateralizedDebt(previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);
    }


    function removeLockedCollateral(uint256 tokenId, address portfolioAccountConfig) external {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedCollateral = collateralManagerData.lockedCollaterals[tokenId];
        // if the token is not accounted for, return early
        if(previousLockedCollateral == 0) {
            return;
        }
        (, uint256 previousMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        collateralManagerData.totalLockedCollateral -= previousLockedCollateral;
        collateralManagerData.lockedCollaterals[tokenId] = 0;
        collateralManagerData.originTimestamps[tokenId] = 0;

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        _updateUndercollateralizedDebt(previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);
    }

    function updateLockedCollateral(address portfolioAccountConfig, uint256 tokenId, address ve) external {
        require(ve != address(0), "Voting escrow address cannot be zero");
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedCollateral = collateralManagerData.lockedCollaterals[tokenId];

        // only update collateral for tokens that are already collateralized
        if(previousLockedCollateral == 0) {
            return;
        }

        (, uint256 previousMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
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
        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        _updateUndercollateralizedDebt(previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);
    }

    function getTotalLockedCollateral() public view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.totalLockedCollateral;
    }

    function getTotalDebt() public view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.debt;
    }

    function getUnpaidFees() public view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.unpaidFees;
    }

    function increaseTotalDebt(address portfolioAccountConfig, uint256 amount) external {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        ILoan loanContract = ILoan(PortfolioAccountConfig(portfolioAccountConfig).getLoanContract());

        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        // if the amount is greater than the max loan (vault supply constraints), add to bad debt
        if (amount > maxLoan) {
            collateralManagerData.badDebt += amount - maxLoan;
        }
        // if the amount is greater than the max loan ignore supply (collateral-based), add to undercollateralized debt
        if(amount > maxLoanIgnoreSupply) {
            collateralManagerData.undercollateralizedDebt += amount - maxLoanIgnoreSupply;
        }
        collateralManagerData.debt += amount;
        loanContract.borrowFromPortfolio(amount);
    }

    function migrateDebt(address portfolioAccountConfig, uint256 amount, uint256 unpaidFees) external {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        collateralManagerData.debt += amount;
        collateralManagerData.unpaidFees += unpaidFees;
    }

    function decreaseTotalDebt(address portfolioAccountConfig, uint256 amount) external returns (uint256 excess) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        
        // get the total debt to ensure we don't overpay
        uint256 totalDebt = collateralManagerData.debt;
        uint256 balancePayment = totalDebt > amount ? amount : totalDebt;
        excess = amount - balancePayment;

        if(collateralManagerData.badDebt > 0) {
            collateralManagerData.badDebt -= collateralManagerData.badDebt > balancePayment ? balancePayment : collateralManagerData.badDebt;
        }
        
        // for accounts migrated over, unpaid fees must be sent to protocol owner first as a balance payment
        ILoan loanContract = ILoan(PortfolioAccountConfig(portfolioAccountConfig).getLoanContract());
        uint256 feesToPay = collateralManagerData.unpaidFees > balancePayment ? balancePayment : collateralManagerData.unpaidFees;

        IERC20(loanContract._asset()).approve(address(loanContract), balancePayment);
        loanContract.payFromPortfolio(balancePayment, feesToPay);
        IERC20(loanContract._asset()).approve(address(loanContract), 0);
        
        collateralManagerData.debt -= balancePayment;
        collateralManagerData.unpaidFees -= feesToPay;
        
        // Recalculate undercollateralized debt after debt reduction
        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        uint256 newTotalDebt = collateralManagerData.debt;
        if(newTotalDebt > maxLoanIgnoreSupply) {
            collateralManagerData.undercollateralizedDebt = newTotalDebt - maxLoanIgnoreSupply;
        } else {
            collateralManagerData.undercollateralizedDebt = 0;
        }
        
        return excess;
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

        return getMaxLoanByRewardsRate(totalLockedCollateral, rewardsRate, multiplier, vaultBalance, outstandingCapital, currentLoanBalance);
    }

    function getOriginTimestamp(uint256 tokenId) external view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.originTimestamps[tokenId];
    }

    /**
     * @dev Enforce collateral requirements
     * @return success True if collateral requirements are met, revert otherwise
     * @notice The bad debt is the debt that is not being paid back by the user, this should always be 0 at the end of every transaction
     * @notice The undercollateralized debt is the debt that is not being covered by the collateral, this should always be 0 at the end of every transaction
     * @notice The collateral requirements are:
     * - No bad debt: The debt that is not being paid back by the user, this should always be 0 at the end of every transaction
     * - No undercollateralized debt: The debt that is not being covered by the collateral, this should always be 0 at the end of every transaction
     * -- We assume when rewards rate decreases and users become undercollateralized, the debt will still be covered by the collateral as it will pay over time
     */
    function enforceCollateralRequirements() external view returns (bool success) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        console.log("enforceCollateralRequirements");
        if(collateralManagerData.badDebt > 0) {
            revert BadDebt(collateralManagerData.badDebt);
        }
        if(collateralManagerData.undercollateralizedDebt > 0) {
            revert UndercollateralizedDebt(collateralManagerData.undercollateralizedDebt);
        }
        return true;
    }

    function getMaxLoanByRewardsRate(
        uint256 veBalance,
        uint256 rewardsRate,
        uint256 multiplier,
        uint256 vaultBalance,
        uint256 outstandingCapital,
        uint256 currentLoanBalance
    ) internal pure returns (uint256, uint256) {
        // Calculate the maximum loan ignoring vault supply constraints
        uint256 maxLoanIgnoreSupply = (((veBalance * rewardsRate) / 1000000) *
            multiplier) / 1e12; // rewardsRate * veNFT balance of token

        // Calculate the maximum utilization ratio (80% of the vault supply)
        uint256 vaultSupply = vaultBalance + outstandingCapital;
        uint256 maxUtilization = (vaultSupply * 8000) / 10000;

        // If the vault is over-utilized, no loans can be made
        if (outstandingCapital >= maxUtilization) {
            return (0, maxLoanIgnoreSupply);
        }

        // If the current loan balance exceeds the maximum capacity, no additional loans can be made
        if (currentLoanBalance >= maxLoanIgnoreSupply) {
            return (0, maxLoanIgnoreSupply);
        }

        uint256 maxLoan = maxLoanIgnoreSupply - currentLoanBalance;

        // Ensure the loan amount does not exceed the available vault supply
        uint256 vaultAvailableSupply = maxUtilization - outstandingCapital;
        if (maxLoan > vaultAvailableSupply) {
            maxLoan = vaultAvailableSupply;
        }

        // Ensure the loan amount does not exceed the vault's current balance
        if (maxLoan > vaultBalance) {
            maxLoan = vaultBalance;
        }

        return (maxLoan, maxLoanIgnoreSupply);
    }

    function _updateUndercollateralizedDebt(uint256 previousMaxLoanIgnoreSupply, uint256 newMaxLoanIgnoreSupply) internal {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 totalDebt = collateralManagerData.debt;
        
        bool isRemovingCollateral = previousMaxLoanIgnoreSupply > newMaxLoanIgnoreSupply;
        console.log("isRemovingCollateral", isRemovingCollateral);
        console.log("previousMaxLoanIgnoreSupply", previousMaxLoanIgnoreSupply);
        console.log("newMaxLoanIgnoreSupply", newMaxLoanIgnoreSupply);
        if(totalDebt < newMaxLoanIgnoreSupply) {
            collateralManagerData.undercollateralizedDebt = 0;
            console.log("totalDebt < newMaxLoanIgnoreSupply");        
            console.log("collateralManagerData.undercollateralizedDebt", collateralManagerData.undercollateralizedDebt);
            return;
        }
        console.log("totalDebt", totalDebt);
        console.log("newMaxLoanIgnoreSupply", newMaxLoanIgnoreSupply);
        console.log("previousMaxLoanIgnoreSupply", previousMaxLoanIgnoreSupply);
        uint256 totalDebtMinusNewMaxLoanIgnoreSupply = totalDebt - newMaxLoanIgnoreSupply;
        // Safe subtraction: if totalDebt < previousMaxLoanIgnoreSupply, then undercollateralized debt was 0 before
        uint256 totalDebtMinusPreviousMaxLoanIgnoreSupply = totalDebt >= previousMaxLoanIgnoreSupply 
            ? totalDebt - previousMaxLoanIgnoreSupply 
            : 0;
        console.log("totalDebtMinusPreviousMaxLoanIgnoreSupply", totalDebtMinusPreviousMaxLoanIgnoreSupply);
        console.log("totalDebtMinusNewMaxLoanIgnoreSupply", totalDebtMinusNewMaxLoanIgnoreSupply);
        
        // Calculate the change in undercollateralized debt
        // Safe subtraction to avoid underflow
        uint256 difference;
        if(isRemovingCollateral) {
            // When removing collateral, undercollateralized debt increases
            // difference = newUndercollateralizedDebt - oldUndercollateralizedDebt
            if(totalDebtMinusNewMaxLoanIgnoreSupply >= totalDebtMinusPreviousMaxLoanIgnoreSupply) {
                difference = totalDebtMinusNewMaxLoanIgnoreSupply - totalDebtMinusPreviousMaxLoanIgnoreSupply;
            } else {
                // This shouldn't happen when removing collateral, but handle it safely
                difference = 0;
            }
        } else {
            // When adding collateral, undercollateralized debt decreases
            // difference = oldUndercollateralizedDebt - newUndercollateralizedDebt
            if(totalDebtMinusPreviousMaxLoanIgnoreSupply >= totalDebtMinusNewMaxLoanIgnoreSupply) {
                difference = totalDebtMinusPreviousMaxLoanIgnoreSupply - totalDebtMinusNewMaxLoanIgnoreSupply;
            } else {
                // This shouldn't happen when adding collateral, but handle it safely
                difference = 0;
            }
        }
        
        // Recalculate undercollateralized debt based on current state
        console.log("totalDebtMinusNewMaxLoanIgnoreSupply", totalDebtMinusNewMaxLoanIgnoreSupply);
        if(isRemovingCollateral) {
            collateralManagerData.undercollateralizedDebt += difference;
        } else {
            if(collateralManagerData.undercollateralizedDebt < difference) {
                collateralManagerData.undercollateralizedDebt = 0;
            } else {
                collateralManagerData.undercollateralizedDebt -= difference;
            }
        }
        console.log("collateralManagerData.undercollateralizedDebt", collateralManagerData.undercollateralizedDebt);
    }
}
