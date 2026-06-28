// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import { LoanUtils } from "../../../LoanUtils.sol";
import {ILoanConfig} from "../config/ILoanConfig.sol";

import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {ILendingVault} from "../../../interfaces/ILendingVault.sol";
import {PortfolioFactoryConfig} from "../config/PortfolioFactoryConfig.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../accounts/PortfolioManager.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

        int128 lockedInt = IVotingEscrow(ve).locked(tokenId).amount;
        require(lockedInt > 0, "Locked collateral amount must be greater than 0");
        uint256 locked = uint256(uint128(lockedInt));
        require(locked >= PortfolioFactoryConfig(portfolioFactoryConfig).getMinimumCollateral(), "Amount below minimum collateral");

        _addLockedCollateral(portfolioFactoryConfig, tokenId, ve);

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        _updateUndercollateralizedDebt(portfolioFactoryConfig, previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);
    }

    function migrateLockedCollateral(address portfolioFactoryConfig, uint256 tokenId, address ve) external {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        if(collateralManagerData.lockedCollaterals[tokenId] != 0) return;
        
        (, uint256 previousMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);

        // Enforce permanent lock on migrated tokens (same as addLockedCollateral)
        if(!IVotingEscrow(address(ve)).locked(tokenId).isPermanent) {
            IVotingEscrow(address(ve)).lockPermanent(tokenId);
        }
        _addLockedCollateral(portfolioFactoryConfig, tokenId, ve);

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        _updateUndercollateralizedDebt(portfolioFactoryConfig, previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);
    }

    function _addLockedCollateral(address portfolioFactoryConfig, uint256 tokenId, address ve) internal {
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
        _updateUndercollateralizedDebt(portfolioFactoryConfig, previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);

        uint256 totalDebt = getTotalDebt(portfolioFactoryConfig);
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
        _updateUndercollateralizedDebt(portfolioFactoryConfig, previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);
    }

    function getTotalLockedCollateral() public view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.totalLockedCollateral;
    }

    /// @notice stored debt, guard against donation manipulation
    function getTotalDebt(address portfolioFactoryConfig) public view returns (uint256) {
        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());
        return lendingPool.getDebtBalance(address(this));
    }

    /// @notice Stored debt minus vested rewards.
    function getEffectiveTotalDebt(address portfolioFactoryConfig) public view returns (uint256) {
        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());
        return lendingPool.getEffectiveDebtBalance(address(this));
    }

    function increaseTotalDebt(address portfolioFactoryConfig, uint256 amount) external returns (uint256 loanAmount, uint256 originationFee) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        // Ensure debt can only be increased via PortfolioManager multicall or authorized callers
        address factory = PortfolioFactoryConfig(portfolioFactoryConfig).getPortfolioFactory();
        PortfolioManager manager = PortfolioFactory(factory).portfolioManager();
        bool isAuthorizedCaller = manager.isAuthorizedCaller(msg.sender);
        if (msg.sender != address(manager) && !isAuthorizedCaller) revert NotPortfolioManager();
        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());

        // Pre-borrow supply-side check. maxLoan derives from vault.totalAssets() and
        // LoanConfig.getMaxUtilizationBps(); any request above that lands the excess on
        // the supply-side flag. PortfolioManager.multicall.enforceCollateralRequirements()
        // reverts at end of tx if non-zero.
        (uint256 maxLoan,) = getMaxLoan(portfolioFactoryConfig);
        if (amount > maxLoan) {
            collateralManagerData.overSuppliedVaultDebt += amount - maxLoan;
        }

        originationFee = lendingPool.borrowFromPortfolio(amount);
        loanAmount = amount - originationFee;

        // Post-borrow collateral-side check. undercollateralizedDebt mirrors actual debt
        // against the rewards-rate / collateral ceiling. Set absolutely from current state.
        uint256 actualTotalDebt = lendingPool.getDebtBalance(address(this));
        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        if (actualTotalDebt > maxLoanIgnoreSupply) {
            collateralManagerData.undercollateralizedDebt = actualTotalDebt - maxLoanIgnoreSupply;
        } else {
            collateralManagerData.undercollateralizedDebt = 0;
        }

        // Multicall callers get end-of-tx enforce via PortfolioManager.multicall.
        // Authorized callers (e.g. topUp) bypass that wrapper, so enforce inline so the
        // cap invariant holds regardless of caller path.
        if (isAuthorizedCaller) {
            enforceCollateralRequirements();
        }

        return (loanAmount, originationFee);
    }

    function decreaseTotalDebt(address portfolioFactoryConfig, uint256 amount) external returns (uint256 excess) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();

        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());
        address lendingAsset = lendingPool.lendingAsset();

        uint256 actualPaid;
        // Pay vault first, vault settles vested rewards then applies payment.
        if (amount > 0) {
            IERC20(lendingAsset).approve(address(lendingPool), amount);
            actualPaid = lendingPool.payFromPortfolio(amount, 0);
            IERC20(lendingAsset).approve(address(lendingPool), 0);
            excess = amount - actualPaid;
        } else {
            excess = 0;
        }

        // Decrement supply-side flag by the amount actually paid down, clamped at zero.
        // Repays must never revert, so we only reduce the flag instead of reading global state.
        uint256 prevOverSupplied = collateralManagerData.overSuppliedVaultDebt;
        if (prevOverSupplied > 0) {
            collateralManagerData.overSuppliedVaultDebt =
                prevOverSupplied > actualPaid ? prevOverSupplied - actualPaid : 0;
        }

        // Recompute collateral-side flag from actual post-payment debt. Debt can only
        // shrink on a repay (collateral untouched), so this only ever clears or lowers.
        uint256 actualTotalDebt = lendingPool.getDebtBalance(address(this));
        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        if (actualTotalDebt > maxLoanIgnoreSupply) {
            collateralManagerData.undercollateralizedDebt = actualTotalDebt - maxLoanIgnoreSupply;
        } else {
            collateralManagerData.undercollateralizedDebt = 0;
        }

        return excess;
    }

    function getMaxLoan(address portfolioFactoryConfig) public view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        uint256 totalLockedCollateral = getTotalLockedCollateral();
        ILoanConfig loanConfig = PortfolioFactoryConfig(portfolioFactoryConfig).getLoanConfig();
        uint256 rewardsRate = loanConfig.getRewardsRate();
        uint256 multiplier = loanConfig.getMultiplier();

        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());
        uint256 outstandingCapital = lendingPool.activeAssets();

        // Supply source: vault.totalAssets() (already accounts for vesting/escrowed liabilities).
        // Cap source: LoanConfig.getMaxUtilizationBps() (single home for the cap; vault no
        // longer enforces, only the manager-side overSuppliedVaultDebt flag does).
        uint256 vaultTotalAssets = ILendingVault(lendingPool.lendingVault()).borrowableTotalAssets();
        uint256 maxUtilizationBps = loanConfig.getMaxUtilizationBps();

        uint256 currentLoanBalance = getTotalDebt(portfolioFactoryConfig);

        return getMaxLoanByRewardsRate(totalLockedCollateral, rewardsRate, multiplier, vaultTotalAssets, outstandingCapital, currentLoanBalance, maxUtilizationBps);
    }

    function getOriginTimestamp(uint256 tokenId) external view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.originTimestamps[tokenId];
    }

    function getLockedCollateral(uint256 tokenId) external view returns (uint256) {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        return collateralManagerData.lockedCollaterals[tokenId];
    }

    /// @dev Returns per-borrower LTV in bps: 0 = no debt, 100_00 = at LTV limit, >100_00 = underwater.
    function getLoanUtilization(address portfolioFactoryConfig) public view returns (uint256) {
        uint256 totalDebt = getTotalDebt(portfolioFactoryConfig);
        if (totalDebt == 0) return 0;

        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig);
        if (maxLoanIgnoreSupply == 0) return type(uint256).max;

        return (totalDebt * 100_00) / maxLoanIgnoreSupply;
    }

    function enforceCollateralRequirements() public view returns (bool success) {
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
        uint256 vaultTotalAssets,
        uint256 outstandingCapital,
        uint256 currentLoanBalance,
        uint256 maxUtilizationBps
    ) internal pure returns (uint256, uint256) {
        // Calculate the maximum loan ignoring vault supply constraints
        uint256 maxLoanIgnoreSupply = (((veBalance * rewardsRate) / 1000000) *
            multiplier) / 1e12; // rewardsRate * veNFT balance of token

        uint256 maxUtilization = (vaultTotalAssets * maxUtilizationBps) / 10000;

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

    function _updateUndercollateralizedDebt(address portfolioFactoryConfig, uint256 previousMaxLoanIgnoreSupply, uint256 newMaxLoanIgnoreSupply) internal {
        CollateralManagerData storage collateralManagerData = _getCollateralManagerData();
        uint256 totalDebt = getTotalDebt(portfolioFactoryConfig);

        bool isRemovingCollateral = previousMaxLoanIgnoreSupply > newMaxLoanIgnoreSupply;

        // If debt is now fully covered, set undercollateralized debt to 0
        if(totalDebt <= newMaxLoanIgnoreSupply) {
            collateralManagerData.undercollateralizedDebt = 0;
            return;
        }

        // prev == new means borrowing capacity is unchanged; leave the delta tracker alone (no-op).

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
     * @return requiredPayment The minimum amount to pass to decreaseTotalDebt
     */
    function getRequiredPaymentForCollateralRemoval(address portfolioFactoryConfig, uint256 tokenId) public view returns (uint256) {
        CollateralManagerData storage data = _getCollateralManagerData();
        // Quote against stored debt to avoid utilization-sensitive drift
        // between quote and execution. The borrower/lender vesting split is
        // global and shifts with utilization; a mempool actor could change
        // utilization between an off-chain quote and the on-chain repayment,
        // making the pre-quoted amount insufficient at settlement and
        // reverting removeLockedCollateral. Stored debt is utilization-stable.
        uint256 currentDebt = getTotalDebt(portfolioFactoryConfig);
        if (currentDebt == 0) return 0;

        uint256 nftCollateral = data.lockedCollaterals[tokenId];
        if (nftCollateral == 0) return 0;

        uint256 newTotalCollateral = data.totalLockedCollateral - nftCollateral;

        ILoanConfig loanConfig = PortfolioFactoryConfig(portfolioFactoryConfig).getLoanConfig();
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
