// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import { LoanUtils } from "../../../LoanUtils.sol";
import {ILoanConfig} from "../config/ILoanConfig.sol";

import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../accounts/PortfolioManager.sol";

import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IDynamicFeesVault {
    function getDebtBalance(address borrower) external view returns (uint256);
    function getEffectiveDebtBalance(address borrower) external view returns (uint256);
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
    error NotPortfolioManager();
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
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        if(collateralManagerData.lockedCollaterals[tokenId] != 0) return;
        
        (, uint256 previousMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);

        // Enforce permanent lock on migrated tokens (same as addLockedCollateral)
        if(!IVotingEscrow(address(ve)).locked(tokenId).isPermanent) {
            IVotingEscrow(address(ve)).lockPermanent(tokenId);
        }
        _addLockedCollateral(portfolioAccountConfig, tokenId, ve);

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        _updateUndercollateralizedDebt(portfolioAccountConfig, previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);
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
        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        _updateUndercollateralizedDebt(portfolioAccountConfig, previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);
    }

    function getTotalLockedCollateral() public view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.totalLockedCollateral;
    }

    function getTotalDebt(address portfolioAccountConfig) public view returns (uint256) {
        ILendingPool lendingPool = ILendingPool(PortfolioAccountConfig(portfolioAccountConfig).getLoanContract());
        return IDynamicFeesVault(address(lendingPool)).getEffectiveDebtBalance(address(this));
    }

    function getUnpaidFees() public pure returns (uint256) {
        return 0;
    }

    function increaseTotalDebt(address portfolioAccountConfig, uint256 amount) external returns (uint256 loanAmount, uint256 originationFee) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        // Ensure debt can only be increased via PortfolioManager multicall or authorized callers
        address factory = PortfolioAccountConfig(portfolioAccountConfig).getPortfolioFactory();
        PortfolioManager manager = PortfolioFactory(factory).portfolioManager();
        if (msg.sender != address(manager) && !manager.isAuthorizedCaller(msg.sender)) revert NotPortfolioManager();
        ILendingPool lendingPool = ILendingPool(PortfolioAccountConfig(portfolioAccountConfig).getLoanContract());

        originationFee = lendingPool.borrowFromPortfolio(amount);
        loanAmount = amount - originationFee;

        uint256 actualTotalDebt = IDynamicFeesVault(address(lendingPool)).getDebtBalance(address(this));
        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);

        // Update enforcement flags based on actual post-borrow state
        if (actualTotalDebt > maxLoanIgnoreSupply) {
            uint256 excess = actualTotalDebt - maxLoanIgnoreSupply;
            collateralManagerData.overSuppliedVaultDebt = excess;
            collateralManagerData.undercollateralizedDebt = excess;
        } else {
            collateralManagerData.overSuppliedVaultDebt = 0;
            collateralManagerData.undercollateralizedDebt = 0;
        }

        return (loanAmount, originationFee);
    }

    function decreaseTotalDebt(address portfolioAccountConfig, uint256 amount) external returns (uint256 excess) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();

        ILendingPool lendingPool = ILendingPool(PortfolioAccountConfig(portfolioAccountConfig).getLoanContract());
        address lendingAsset = lendingPool.lendingAsset();

        // Pay vault first — vault settles vested rewards then applies payment.
        if (amount > 0) {
            IERC20(lendingAsset).approve(address(lendingPool), amount);
            uint256 actualPaid = lendingPool.payFromPortfolio(amount, 0);
            IERC20(lendingAsset).approve(address(lendingPool), 0);
            excess = amount - actualPaid;
        } else {
            excess = 0;
        }

        // Read actual post-payment, post-settlement debt for accurate enforcement
        uint256 actualTotalDebt = IDynamicFeesVault(address(lendingPool)).getDebtBalance(address(this));
        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);

        // Update enforcement flags based on actual post-payment state
        if (actualTotalDebt > maxLoanIgnoreSupply) {
            uint256 debtExcess = actualTotalDebt - maxLoanIgnoreSupply;
            collateralManagerData.overSuppliedVaultDebt = debtExcess;
            collateralManagerData.undercollateralizedDebt = debtExcess;
        } else {
            collateralManagerData.overSuppliedVaultDebt = 0;
            collateralManagerData.undercollateralizedDebt = 0;
        }

        return excess;
    }

    function getMaxLoan(address portfolioAccountConfig) public view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        uint256 totalLockedCollateral = getTotalLockedCollateral();
        ILoanConfig loanConfig = PortfolioAccountConfig(portfolioAccountConfig).getLoanConfig();
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

        // NOTE: When previousMaxLoanIgnoreSupply == newMaxLoanIgnoreSupply (e.g., repayment
        // where only debt changes), the delta is 0 and undercollateralizedDebt is unchanged.
        // This can leave a stale value that overstates the actual shortfall. However, it does
        // NOT affect transaction outcomes — the early return above already zeroes
        // undercollateralizedDebt when totalDebt <= maxLoanIgnoreSupply, so enforceCollateralRequirements
        // pass/fail is always correct. The stale value only affects the revert message amount.
    }

    /**
     * @dev Calculate the minimum payment needed to keep account in good standing after removing a specific token's collateral
     * @param portfolioAccountConfig The portfolio account config address
     * @param tokenId The token ID whose collateral will be removed
     * @return requiredPayment The minimum amount to pass to decreaseTotalDebt
     */
    function getRequiredPaymentForCollateralRemoval(address portfolioAccountConfig, uint256 tokenId) public view returns (uint256) {
        CollateralManagerData storage data = _getCollateralManagerData();
        uint256 currentDebt = getTotalDebt(portfolioAccountConfig);
        if (currentDebt == 0) return 0;

        uint256 nftCollateral = data.lockedCollaterals[tokenId];
        if (nftCollateral == 0) return 0;

        uint256 newTotalCollateral = data.totalLockedCollateral - nftCollateral;

        ILoanConfig loanConfig = PortfolioAccountConfig(portfolioAccountConfig).getLoanConfig();
        uint256 rewardsRate = loanConfig.getRewardsRate();
        uint256 multiplier = loanConfig.getMultiplier();

        uint256 newMaxLoanIgnoreSupply = (((newTotalCollateral * rewardsRate) / 1000000) * multiplier) / 1e12;

        if (currentDebt <= newMaxLoanIgnoreSupply) return 0;

        // No unpaidFees for DynamicCollateralManager (fees handled by vault)
        return currentDebt - newMaxLoanIgnoreSupply;
    }

    function migrateDebt(address, uint256, uint256) external pure {
        revert NotSupported();
    }
}
