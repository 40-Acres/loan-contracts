// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import { LoanUtils } from "../../../LoanUtils.sol";
import {LoanConfig} from "../config/LoanConfig.sol";

import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";

import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IDynamicFeesVault {
    function getDebtBalance(address borrower) external view returns (uint256);
}

/**
 * @title DynamicCollateralManager
 * @dev Variant of CollateralManager for DynamicFeesVault.
 *      Reads debt directly from the vault instead of tracking it locally.
 *      No unpaidFees tracking — users must pay those off before migrating.
 */
library DynamicCollateralManager {
    error InsufficientCollateral();
    error InvalidLockedCollateral();
    error BadDebt(uint256 debt);
    error UndercollateralizedDebt(uint256 debt);
    error NotSupported();
    event CollateralAdded(uint256 indexed tokenId, address indexed owner);
    event CollateralRemoved(uint256 indexed tokenId, address indexed owner);

    struct CollateralManagerData {
        mapping(uint256 tokenId => uint256 lockedCollateral) lockedCollaterals;
        mapping(uint256 tokenId => uint256 originTimestamp) originTimestamps;
        uint256 totalLockedCollateral;
        uint256 overSuppliedVaultDebt;
        uint256 undercollateralizedDebt;
    }

    function _getCollateralManagerData() internal pure returns (CollateralManagerData storage collateralManagerData) {
        bytes32 position = keccak256("storage.DynamicCollateralManager");
        assembly {
            collateralManagerData.slot := position
        }
    }

    function addLockedCollateral(address portfolioAccountConfig, uint256 tokenId, address ve) external {

        // ensure locked is permanent
        if(!IVotingEscrow(address(ve)).locked(tokenId).isPermanent) {
            IVotingEscrow(address(ve)).lockPermanent(tokenId);
        }

        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedCollateral = collateralManagerData.lockedCollaterals[tokenId];
        (, uint256 previousMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        // if the token is already accounted for, return early
        if(previousLockedCollateral != 0) {
            return;
        }


        _addLockedCollateral(portfolioAccountConfig, tokenId, ve);

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        _updateUndercollateralizedDebt(portfolioAccountConfig, previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);
    }

    function migrateLockedCollateral(address portfolioAccountConfig, uint256 tokenId, address ve) external {
        _addLockedCollateral(portfolioAccountConfig, tokenId, ve);
    }

    function _addLockedCollateral(address portfolioAccountConfig, uint256 tokenId, address ve) internal {
        // require the token to be in the portfolio account
        require(IVotingEscrow(address(ve)).ownerOf(tokenId) == address(this), "Token not in portfolio account");
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        require(ve != address(0), "Voting escrow address cannot be zero");

        int128 newLockedCollateralInt = IVotingEscrow(address(ve)).locked(tokenId).amount;
        require(newLockedCollateralInt > 0, "Locked collateral amount must be greater than 0");
        uint256 newLockedCollateral = uint256(uint128(newLockedCollateralInt));

        collateralManagerData.lockedCollaterals[tokenId] = newLockedCollateral;
        collateralManagerData.totalLockedCollateral += newLockedCollateral;
        collateralManagerData.originTimestamps[tokenId] = block.timestamp;

        emit CollateralAdded(tokenId, address(this));
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
        _updateUndercollateralizedDebt(portfolioAccountConfig, previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);

        emit CollateralRemoved(tokenId, address(this));
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
        require(newLockedCollateralInt >= 0, "Locked collateral amount must be greater than 0");
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
        _updateUndercollateralizedDebt(portfolioAccountConfig, previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);
    }

    function getTotalLockedCollateral() public view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.totalLockedCollateral;
    }

    function getTotalDebt(address portfolioAccountConfig) public view returns (uint256) {
        ILendingPool lendingPool = ILendingPool(PortfolioAccountConfig(portfolioAccountConfig).getLoanContract());
        return IDynamicFeesVault(address(lendingPool)).getDebtBalance(address(this));
    }

    function getUnpaidFees() public pure returns (uint256) {
        return 0;
    }

    function increaseTotalDebt(address portfolioAccountConfig, uint256 amount) external returns (uint256 loanAmount, uint256 originationFee) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        ILendingPool lendingPool = ILendingPool(PortfolioAccountConfig(portfolioAccountConfig).getLoanContract());

        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        // if the amount is greater than the max loan (vault supply constraints), add to bad debt
        if (amount > maxLoan) {
            collateralManagerData.overSuppliedVaultDebt += amount - maxLoan;
        }

        // Read current vault debt to compute projected total
        uint256 currentVaultDebt = IDynamicFeesVault(address(lendingPool)).getDebtBalance(address(this));
        uint256 projectedTotalDebt = currentVaultDebt + amount;
        if (projectedTotalDebt > maxLoanIgnoreSupply) {
            collateralManagerData.undercollateralizedDebt += projectedTotalDebt - maxLoanIgnoreSupply;
        }

        // Borrow from vault — vault tracks the debt internally
        originationFee = lendingPool.borrowFromPortfolio(amount);
        loanAmount = amount - originationFee;
        return (loanAmount, originationFee);
    }

    function decreaseTotalDebt(address portfolioAccountConfig, uint256 amount) external returns (uint256 excess) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();

        ILendingPool lendingPool = ILendingPool(PortfolioAccountConfig(portfolioAccountConfig).getLoanContract());
        address lendingAsset = lendingPool.lendingAsset();

        // Read current vault debt to ensure we don't overpay
        uint256 totalDebt = IDynamicFeesVault(address(lendingPool)).getDebtBalance(address(this));
        uint256 balancePayment = totalDebt > amount ? amount : totalDebt;
        excess = amount - balancePayment;

        (, uint256 previousMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);

        if(collateralManagerData.overSuppliedVaultDebt > 0) {
            collateralManagerData.overSuppliedVaultDebt -= collateralManagerData.overSuppliedVaultDebt > balancePayment ? balancePayment : collateralManagerData.overSuppliedVaultDebt;
        }

        if (balancePayment > 0) {
            // Measure USDC balance before/after to determine exact amount paid
            // (vault may reduce debt via rewards vesting during the call)
            uint256 usdcBefore = IERC20(lendingAsset).balanceOf(address(this));
            IERC20(lendingAsset).approve(address(lendingPool), balancePayment);
            lendingPool.payFromPortfolio(balancePayment, 0);
            IERC20(lendingAsset).approve(address(lendingPool), 0);
            uint256 actualPaid = usdcBefore - IERC20(lendingAsset).balanceOf(address(this));
            excess = amount - actualPaid;
        }

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        _updateUndercollateralizedDebt(portfolioAccountConfig, previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);

        return excess;
    }

    function getMaxLoan(address portfolioAccountConfig) public view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        uint256 totalLockedCollateral = getTotalLockedCollateral();
        LoanConfig loanConfig = PortfolioAccountConfig(portfolioAccountConfig).getLoanConfig();
        uint256 rewardsRate = loanConfig.getRewardsRate();
        uint256 multiplier = loanConfig.getMultiplier();

        ILendingPool lendingPool = ILendingPool(PortfolioAccountConfig(portfolioAccountConfig).getLoanContract());
        uint256 outstandingCapital = lendingPool.activeAssets();

        address vault = lendingPool.lendingVault();
        IERC4626 vaultAsset = IERC4626(vault);
        // Get the underlying asset balance in the vault
        address underlyingAsset = vaultAsset.asset();
        uint256 vaultBalance = IERC20(underlyingAsset).balanceOf(address(vault));

        // Get current total debt from the vault
        uint256 currentLoanBalance = getTotalDebt(portfolioAccountConfig);

        return getMaxLoanByRewardsRate(totalLockedCollateral, rewardsRate, multiplier, vaultBalance, outstandingCapital, currentLoanBalance);
    }

    function getOriginTimestamp(uint256 tokenId) external view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.originTimestamps[tokenId];
    }

    function getLockedCollateral(uint256 tokenId) external view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.lockedCollaterals[tokenId];
    }

    function enforceCollateralRequirements() external view returns (bool success) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        if(collateralManagerData.overSuppliedVaultDebt > 0) {
            revert BadDebt(collateralManagerData.overSuppliedVaultDebt);
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

        return (maxLoan, maxLoanIgnoreSupply);
    }

    function _updateUndercollateralizedDebt(address portfolioAccountConfig, uint256 previousMaxLoanIgnoreSupply, uint256 newMaxLoanIgnoreSupply) internal {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 totalDebt = getTotalDebt(portfolioAccountConfig);

        bool isRemovingCollateral = previousMaxLoanIgnoreSupply > newMaxLoanIgnoreSupply;

        // If debt is now fully covered, set undercollateralized debt to 0
        if(totalDebt <= newMaxLoanIgnoreSupply) {
            collateralManagerData.undercollateralizedDebt = 0;
            return;
        }

        uint256 difference;
        if(isRemovingCollateral) {
            difference = previousMaxLoanIgnoreSupply - newMaxLoanIgnoreSupply;
            collateralManagerData.undercollateralizedDebt += difference;
        } else {
            difference = newMaxLoanIgnoreSupply - previousMaxLoanIgnoreSupply;
            if(collateralManagerData.undercollateralizedDebt < difference) {
                collateralManagerData.undercollateralizedDebt = 0;
            } else {
                collateralManagerData.undercollateralizedDebt -= difference;
            }
        }
    }

    function addDebt(address, uint256, uint256) external pure {
        revert NotSupported();
    }

    function transferDebtAway(address, uint256, uint256) external pure {
        revert NotSupported();
    }

    function migrateDebt(address, uint256, uint256) external pure {
        revert NotSupported();
    }
}
