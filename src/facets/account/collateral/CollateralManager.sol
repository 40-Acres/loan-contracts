// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import { LoanUtils } from "../../../LoanUtils.sol";
import {ILoanConfig} from "../config/ILoanConfig.sol";

import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {PortfolioFactoryConfig} from "../config/PortfolioFactoryConfig.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../accounts/PortfolioManager.sol";

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
    error BadDebt(uint256 debt);
    error UndercollateralizedDebt(uint256 debt);
    error NotPortfolioManager();
    event CollateralAdded(uint256 indexed tokenId, address indexed owner);
    event CollateralRemoved(uint256 indexed tokenId, address indexed owner);

    struct CollateralManagerData {
        mapping(uint256 tokenId => uint256 lockedCollateral) lockedCollaterals;
        mapping(uint256 tokenId => uint256 originTimestamp) originTimestamps;
        uint256 totalLockedCollateral;
        uint256 debt;
        uint256 overSuppliedVaultDebt;
        uint256 undercollateralizedDebt;
    }

    function _getCollateralManagerData() internal pure returns (CollateralManagerData storage collateralManagerData) {
        bytes32 position = keccak256("storage.CollateralManager");
        assembly {
            collateralManagerData.slot := position
        }
    }

    function addLockedCollateral(address portfolioFactoryConfig, uint256 tokenId, address ve) external {

        // ensure locked is permanent
        if(!IVotingEscrow(address(ve)).locked(tokenId).isPermanent) {
            IVotingEscrow(address(ve)).lockPermanent(tokenId);
        }
        
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedCollateral = collateralManagerData.lockedCollaterals[tokenId];
        (, uint256 previousMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        // if the token is already accounted for, return early
        if(previousLockedCollateral != 0) {
            return;
        }

        
        _addLockedCollateral(portfolioFactoryConfig, tokenId, ve);

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        _updateUndercollateralizedDebt(previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);
    }

    function migrateLockedCollateral(address portfolioFactoryConfig, uint256 tokenId, address ve) external {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        if(collateralManagerData.lockedCollaterals[tokenId] != 0) return;
        // Enforce permanent lock on migrated tokens (same as addLockedCollateral)
        if(!IVotingEscrow(address(ve)).locked(tokenId).isPermanent) {
            IVotingEscrow(address(ve)).lockPermanent(tokenId);
        }
        _addLockedCollateral(portfolioFactoryConfig, tokenId, ve);
    }

    function _addLockedCollateral(address portfolioFactoryConfig, uint256 tokenId, address ve) internal {
        // require the token to be in the portfolio account
        require(IVotingEscrow(address(ve)).ownerOf(tokenId) == address(this), "Token not in portfolio account");
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();

        int128 newLockedCollateralInt = IVotingEscrow(address(ve)).locked(tokenId).amount;
        require(newLockedCollateralInt > 0, "Locked collateral amount must be greater than 0");
        uint256 newLockedCollateral = uint256(uint128(newLockedCollateralInt));
        
        collateralManagerData.lockedCollaterals[tokenId] = newLockedCollateral;
        collateralManagerData.totalLockedCollateral += newLockedCollateral;
        collateralManagerData.originTimestamps[tokenId] = block.timestamp;

        _notifyCollateralAdded(portfolioFactoryConfig, ve, tokenId);
        emit CollateralAdded(tokenId, address(this));
    }


    function removeLockedCollateral(uint256 tokenId, address portfolioFactoryConfig, address ve) external {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedCollateral = collateralManagerData.lockedCollaterals[tokenId];
        // if the token is not accounted for, return early
        if(previousLockedCollateral == 0) {
            return;
        }
        (, uint256 previousMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        collateralManagerData.totalLockedCollateral -= previousLockedCollateral;
        collateralManagerData.lockedCollaterals[tokenId] = 0;
        collateralManagerData.originTimestamps[tokenId] = 0;

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        _updateUndercollateralizedDebt(previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);

        uint256 totalDebt = collateralManagerData.debt;
        require(totalDebt <= newMaxLoanIgnoreSupply, "Debt exceeds max loan");

        _notifyCollateralRemoved(portfolioFactoryConfig, ve, tokenId);
        emit CollateralRemoved(tokenId, address(this));
    }

    function updateLockedCollateral(address portfolioFactoryConfig, uint256 tokenId, address ve) external {
        require(ve != address(0), "Voting escrow address cannot be zero");
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 previousLockedCollateral = collateralManagerData.lockedCollaterals[tokenId];

        // only update collateral for tokens that are already collateralized
        if(previousLockedCollateral == 0) {
            return;
        }

        (, uint256 previousMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        int128 newLockedCollateralInt = IVotingEscrow(address(ve)).locked(tokenId).amount;
        require(newLockedCollateralInt >= 0);
        uint256 newLockedCollateral = uint256(uint128(newLockedCollateralInt));
        if(newLockedCollateral > previousLockedCollateral) {
            uint256 difference = newLockedCollateral - previousLockedCollateral;
            collateralManagerData.totalLockedCollateral += difference;
        } else {
            uint256 difference = previousLockedCollateral - newLockedCollateral;
            collateralManagerData.totalLockedCollateral -= difference;
        }

        collateralManagerData.lockedCollaterals[tokenId] = newLockedCollateral;
        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
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
    
    function increaseTotalDebt(address portfolioFactoryConfig, uint256 amount) external returns (uint256 loanAmount, uint256 originationFee) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        // Ensure debt can only be increased via PortfolioManager multicall or authorized callers
        address factory = PortfolioFactoryConfig(portfolioFactoryConfig).getPortfolioFactory();
        PortfolioManager manager = PortfolioFactory(factory).portfolioManager();
        if (msg.sender != address(manager) && !manager.isAuthorizedCaller(msg.sender)) revert NotPortfolioManager();
        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());

        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        // if the amount is greater than the max loan (vault supply constraints), add to bad debt
        if (amount > maxLoan) {
            collateralManagerData.overSuppliedVaultDebt += amount - maxLoan;
        }

        uint256 projectedTotalDebt = collateralManagerData.debt + amount;
        if (projectedTotalDebt > maxLoanIgnoreSupply) {
            collateralManagerData.undercollateralizedDebt = projectedTotalDebt - maxLoanIgnoreSupply;
        }
        collateralManagerData.debt += amount;
        originationFee = lendingPool.borrowFromPortfolio(amount);
        loanAmount = amount - originationFee;
        return (loanAmount, originationFee);
    }

    function migrateDebt(address portfolioFactoryConfig, uint256 amount, uint256 unpaidFees) external {
        require(unpaidFees == 0, "Unpaid fees must be paid in full during migration");
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        collateralManagerData.debt += amount;
    }

    function decreaseTotalDebt(address portfolioFactoryConfig, uint256 amount) external returns (uint256 excess) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();

        // Cap payment at total debt to avoid overpaying
        uint256 totalDebt = collateralManagerData.debt;
        uint256 balancePayment = totalDebt > amount ? amount : totalDebt;

        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());

        IERC20(lendingPool.lendingAsset()).approve(address(lendingPool), balancePayment);
        uint256 actualPaid = lendingPool.payFromPortfolio(balancePayment, 0);
        IERC20(lendingPool.lendingAsset()).approve(address(lendingPool), 0);

        collateralManagerData.debt -= actualPaid;
        excess = amount - actualPaid;

        if(collateralManagerData.overSuppliedVaultDebt > 0) {
            collateralManagerData.overSuppliedVaultDebt -= collateralManagerData.overSuppliedVaultDebt > actualPaid ? actualPaid : collateralManagerData.overSuppliedVaultDebt;
        }

        if(collateralManagerData.undercollateralizedDebt > 0) {
            collateralManagerData.undercollateralizedDebt -= collateralManagerData.undercollateralizedDebt > actualPaid ? actualPaid : collateralManagerData.undercollateralizedDebt;
        }

        return excess;
    }

    function getMaxLoan(address portfolioFactoryConfig) public view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        uint256 totalLockedCollateral = getTotalLockedCollateral();
        ILoanConfig loanConfig = PortfolioFactoryConfig(portfolioFactoryConfig).getLoanConfig();
        uint256 rewardsRate = loanConfig.getRewardsRate();
        uint256 multiplier = loanConfig.getMultiplier();

        address loanContract = PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract();
        uint256 outstandingCapital;
        uint256 vaultBalance;
        if (loanContract != address(0)) {
            ILendingPool lendingPool = ILendingPool(loanContract);
            outstandingCapital = lendingPool.activeAssets();

            address vault = lendingPool.lendingVault();
            if (vault != address(0)) {
                address underlyingAsset = IERC4626(vault).asset();
                vaultBalance = IERC20(underlyingAsset).balanceOf(vault);
            }
        }

        // Get current total debt for the portfolio account
        uint256 currentLoanBalance = getTotalDebt();

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

    function getLTVRatio(address portfolioFactoryConfig) public view returns (uint256) {
        uint256 totalDebt = getTotalDebt();
        if (totalDebt == 0) return 0;

        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        if (maxLoanIgnoreSupply == 0) return type(uint256).max;

        return (totalDebt * 100) / maxLoanIgnoreSupply;
    }

    /**
     * @dev Enforce collateral requirements
     * @return success True if collateral requirements are met, revert otherwise
     * @notice This function prevents any additional debt from being added to the portfolio account
     * @notice The bad debt is the debt that is not being paid back by the user, this should always be 0 at the end of every transaction
     * @notice The undercollateralized debt is the debt that is not being covered by the collateral, this should always be 0 at the end of every transaction
     * @notice The collateral requirements are:
     * - No bad debt: The debt that is not being paid back by the user, this should always be 0 at the end of every transaction
     * - No undercollateralized debt: The debt that is not being covered by the collateral, this should always be 0 at the end of every transaction
     * -- We assume when rewards rate decreases and users become undercollateralized, the debt will still be covered by the collateral as it will pay over time
     */
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

    /**
     * @dev Update the undercollateralized debt
     * @param previousMaxLoanIgnoreSupply The previous max loan ignore supply
     * @param newMaxLoanIgnoreSupply The new max loan ignore supply
     */
    function _updateUndercollateralizedDebt(uint256 previousMaxLoanIgnoreSupply, uint256 newMaxLoanIgnoreSupply) internal {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 totalDebt = collateralManagerData.debt;

        bool isRemovingCollateral = previousMaxLoanIgnoreSupply > newMaxLoanIgnoreSupply;

        // If debt is now fully covered, set undercollateralized debt to 0
        if(totalDebt <= newMaxLoanIgnoreSupply) {
            collateralManagerData.undercollateralizedDebt = 0;
            return;
        }

        // When prev == new (no delta), the incremental logic would be a no-op,
        // but debt > maxLoan means we're undercollateralized. Set the full shortfall.
        if(previousMaxLoanIgnoreSupply == newMaxLoanIgnoreSupply) {
            collateralManagerData.undercollateralizedDebt = totalDebt - newMaxLoanIgnoreSupply;
            return;
        }

        // Calculate the change in undercollateralized debt
        // The difference is simply the change in maxLoanIgnoreSupply:
        // - When removing collateral: maxLoanIgnoreSupply decreases, so undercollateralized debt increases
        // - When adding collateral: maxLoanIgnoreSupply increases, so undercollateralized debt decreases
        uint256 difference;
        if(isRemovingCollateral) {
            // Removing collateral: undercollateralized debt increases by the reduction in maxLoanIgnoreSupply
            difference = previousMaxLoanIgnoreSupply - newMaxLoanIgnoreSupply;
            collateralManagerData.undercollateralizedDebt += difference;
        } else {
            // Adding collateral: undercollateralized debt decreases by the increase in maxLoanIgnoreSupply
            difference = newMaxLoanIgnoreSupply - previousMaxLoanIgnoreSupply;
            if(collateralManagerData.undercollateralizedDebt < difference) {
                collateralManagerData.undercollateralizedDebt = 0;
            } else {
                collateralManagerData.undercollateralizedDebt -= difference;
            }
        }
    }


    function _notifyCollateralAdded(address portfolioFactoryConfig, address ve, uint256 tokenId) internal {
        try PortfolioFactoryConfig(portfolioFactoryConfig).onCollateralAdded(ve, tokenId) {} catch {}
    }

    function _notifyCollateralRemoved(address portfolioFactoryConfig, address ve, uint256 tokenId) internal {
        try PortfolioFactoryConfig(portfolioFactoryConfig).onCollateralRemoved(ve, tokenId) {} catch {}
    }

    /**
     * @dev Calculate the minimum payment needed to keep account in good standing after removing a specific token's collateral
     * @param portfolioFactoryConfig The portfolio account config address
     * @param tokenId The token ID whose collateral will be removed
     * @return requiredPayment The minimum amount to pass to decreaseTotalDebt (includes unpaid fees since they are paid first)
     */
    function getRequiredPaymentForCollateralRemoval(address portfolioFactoryConfig, uint256 tokenId) public view returns (uint256) {
        CollateralManagerData storage data = _getCollateralManagerData();
        uint256 currentDebt = data.debt;
        if (currentDebt == 0) return 0;

        uint256 nftCollateral = data.lockedCollaterals[tokenId];
        if (nftCollateral == 0) return 0;

        uint256 newTotalCollateral = data.totalLockedCollateral - nftCollateral;

        ILoanConfig loanConfig = PortfolioFactoryConfig(portfolioFactoryConfig).getLoanConfig();
        uint256 rewardsRate = loanConfig.getRewardsRate();
        uint256 multiplier = loanConfig.getMultiplier();

        uint256 newMaxLoanIgnoreSupply = (((newTotalCollateral * rewardsRate) / 1000000) * multiplier) / 1e12;

        if (currentDebt <= newMaxLoanIgnoreSupply) return 0;

        uint256 debtReductionNeeded = currentDebt - newMaxLoanIgnoreSupply;
        return debtReductionNeeded;
    }

}
