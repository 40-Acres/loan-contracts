// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LoanConfig} from "../config/LoanConfig.sol";
import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";

/**
 * @title ERC4626CollateralManager
 * @dev Library for managing ERC4626 vault shares as collateral
 * Handles share tracking, collateral value calculation, and debt management
 */
library ERC4626CollateralManager {
    using SafeERC20 for IERC20;

    error InsufficientCollateral();
    error BadDebt(uint256 debt);
    error UndercollateralizedDebt(uint256 debt);

    event ERC4626CollateralAdded(address indexed vault, uint256 shares, uint256 assetValue, address indexed owner);
    event ERC4626CollateralRemoved(address indexed vault, uint256 shares, uint256 assetValue, address indexed owner);

    struct ERC4626CollateralData {
        address vault;               // The ERC4626 vault address
        uint256 shares;              // Shares deposited as collateral
        uint256 depositedAssetValue; // Asset value at time of deposit (for tracking)
        // Debt tracking
        uint256 debt;
        uint256 unpaidFees;
        uint256 overSuppliedVaultDebt;
        uint256 undercollateralizedDebt;
    }

    bytes32 private constant STORAGE_POSITION = keccak256("storage.ERC4626CollateralManager");

    function _getStorage() internal pure returns (ERC4626CollateralData storage data) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            data.slot := position
        }
    }

    /**
     * @dev Add ERC4626 shares as collateral
     * @param portfolioAccountConfig The portfolio account config address
     * @param vault The ERC4626 vault address
     * @param shares The amount of shares to add as collateral
     */
    function addCollateral(address portfolioAccountConfig, address vault, uint256 shares) external {
        require(vault != address(0), "Invalid vault address");
        require(shares > 0, "Shares must be > 0");
        require(IERC20(vault).balanceOf(address(this)) >= shares, "Insufficient shares in wallet");

        ERC4626CollateralData storage data = _getStorage();

        // If first time, set the vault address
        if (data.vault == address(0)) {
            data.vault = vault;
        } else {
            require(data.vault == vault, "Vault mismatch");
        }

        (, uint256 previousMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);

        // Calculate asset value of shares
        uint256 assetValue = IERC4626(vault).convertToAssets(shares);

        data.shares += shares;
        data.depositedAssetValue += assetValue;

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        _updateUndercollateralizedDebt(data, previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);

        emit ERC4626CollateralAdded(vault, shares, assetValue, address(this));
    }

    /**
     * @dev Remove ERC4626 shares from collateral
     * @param portfolioAccountConfig The portfolio account config address
     * @param shares The amount of shares to remove from collateral
     */
    function removeCollateral(address portfolioAccountConfig, uint256 shares) external {
        require(shares > 0, "Shares must be > 0");

        ERC4626CollateralData storage data = _getStorage();
        require(data.shares >= shares, "Insufficient collateral shares");

        (, uint256 previousMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);

        // Calculate proportional asset value to remove
        uint256 assetValueToRemove = (data.depositedAssetValue * shares) / data.shares;

        data.shares -= shares;
        data.depositedAssetValue -= assetValueToRemove;

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        _updateUndercollateralizedDebt(data, previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);

        emit ERC4626CollateralRemoved(data.vault, shares, assetValueToRemove, address(this));
    }

    /**
     * @dev Get total collateral value in underlying assets
     * @return totalValue The total value of collateral in underlying assets
     */
    function getTotalCollateralValue() public view returns (uint256 totalValue) {
        ERC4626CollateralData storage data = _getStorage();
        if (data.shares > 0 && data.vault != address(0)) {
            totalValue = IERC4626(data.vault).convertToAssets(data.shares);
        }
    }

    /**
     * @dev Get collateral info
     * @return vault The vault address
     * @return shares The shares deposited as collateral
     * @return depositedAssetValue The asset value at deposit time
     * @return currentAssetValue The current asset value
     */
    function getCollateral() external view returns (
        address vault,
        uint256 shares,
        uint256 depositedAssetValue,
        uint256 currentAssetValue
    ) {
        ERC4626CollateralData storage data = _getStorage();
        vault = data.vault;
        shares = data.shares;
        depositedAssetValue = data.depositedAssetValue;
        if (shares > 0 && vault != address(0)) {
            currentAssetValue = IERC4626(vault).convertToAssets(shares);
        }
    }

    /**
     * @dev Get the collateral vault address
     */
    function getCollateralVault() external view returns (address) {
        ERC4626CollateralData storage data = _getStorage();
        return data.vault;
    }

    /**
     * @dev Get collateral shares
     */
    function getCollateralShares() external view returns (uint256) {
        ERC4626CollateralData storage data = _getStorage();
        return data.shares;
    }

    /**
     * @dev Get total debt
     */
    function getTotalDebt() public view returns (uint256) {
        ERC4626CollateralData storage data = _getStorage();
        return data.debt;
    }

    /**
     * @dev Get unpaid fees
     */
    function getUnpaidFees() public view returns (uint256) {
        ERC4626CollateralData storage data = _getStorage();
        return data.unpaidFees;
    }

    /**
     * @dev Increase total debt by borrowing from lending pool
     * @param portfolioAccountConfig The portfolio account config address
     * @param amount The amount to borrow
     * @return loanAmount The actual loan amount after fees
     * @return originationFee The origination fee
     */
    function increaseTotalDebt(address portfolioAccountConfig, uint256 amount) external returns (uint256 loanAmount, uint256 originationFee) {
        ERC4626CollateralData storage data = _getStorage();
        ILendingPool lendingPool = ILendingPool(PortfolioAccountConfig(portfolioAccountConfig).getLoanContract());

        (uint256 maxLoan, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);

        if (amount > maxLoan) {
            data.overSuppliedVaultDebt += amount - maxLoan;
        }

        uint256 projectedTotalDebt = data.debt + amount;
        if (projectedTotalDebt > maxLoanIgnoreSupply) {
            data.undercollateralizedDebt += projectedTotalDebt - maxLoanIgnoreSupply;
        }

        data.debt += amount;
        originationFee = lendingPool.borrowFromPortfolio(amount);
        loanAmount = amount - originationFee;
        return (loanAmount, originationFee);
    }

    /**
     * @dev Decrease total debt by paying to lending pool
     * @param portfolioAccountConfig The portfolio account config address
     * @param amount The amount to pay
     * @return excess Any excess amount after fully paying debt
     */
    function decreaseTotalDebt(address portfolioAccountConfig, uint256 amount) external returns (uint256 excess) {
        ERC4626CollateralData storage data = _getStorage();

        uint256 totalDebt = data.debt;
        uint256 balancePayment = totalDebt > amount ? amount : totalDebt;
        excess = amount - balancePayment;

        (, uint256 previousMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);

        if (data.overSuppliedVaultDebt > 0) {
            data.overSuppliedVaultDebt -= data.overSuppliedVaultDebt > balancePayment ? balancePayment : data.overSuppliedVaultDebt;
        }

        ILendingPool lendingPool = ILendingPool(PortfolioAccountConfig(portfolioAccountConfig).getLoanContract());
        uint256 feesToPay = data.unpaidFees > balancePayment ? balancePayment : data.unpaidFees;

        IERC20(lendingPool.lendingAsset()).approve(address(lendingPool), balancePayment);
        lendingPool.payFromPortfolio(balancePayment, feesToPay);
        IERC20(lendingPool.lendingAsset()).approve(address(lendingPool), 0);

        data.debt -= (balancePayment - feesToPay);
        data.unpaidFees -= feesToPay;

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        _updateUndercollateralizedDebt(data, previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);

        return excess;
    }

    /**
     * @dev Get the maximum loan amount based on collateral value
     * @param portfolioAccountConfig The portfolio account config address
     * @return maxLoan The maximum loan considering vault supply constraints
     * @return maxLoanIgnoreSupply The maximum loan ignoring vault supply constraints
     */
    function getMaxLoan(address portfolioAccountConfig) public view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        uint256 totalCollateralValue = getTotalCollateralValue();
        LoanConfig loanConfig = PortfolioAccountConfig(portfolioAccountConfig).getLoanConfig();

        // Get loan-to-value ratio (LTV) from multiplier - e.g., 7000 = 70%
        uint256 ltv = loanConfig.getMultiplier();

        // Calculate max loan based on collateral value and LTV
        maxLoanIgnoreSupply = (totalCollateralValue * ltv) / 10000;

        ILendingPool lendingPool = ILendingPool(PortfolioAccountConfig(portfolioAccountConfig).getLoanContract());
        uint256 outstandingCapital = lendingPool.activeAssets();

        address vault = lendingPool.lendingVault();
        IERC4626 vaultAsset = IERC4626(vault);
        address underlyingAsset = vaultAsset.asset();
        uint256 vaultBalance = IERC20(underlyingAsset).balanceOf(address(vault));

        uint256 currentLoanBalance = getTotalDebt();

        return _calculateMaxLoan(maxLoanIgnoreSupply, vaultBalance, outstandingCapital, currentLoanBalance);
    }

    function _calculateMaxLoan(
        uint256 maxLoanIgnoreSupply,
        uint256 vaultBalance,
        uint256 outstandingCapital,
        uint256 currentLoanBalance
    ) internal pure returns (uint256 maxLoan, uint256 maxLoanIgnoreSupplyOut) {
        maxLoanIgnoreSupplyOut = maxLoanIgnoreSupply;

        uint256 vaultSupply = vaultBalance + outstandingCapital;
        uint256 maxUtilization = (vaultSupply * 8000) / 10000;

        if (outstandingCapital >= maxUtilization) {
            return (0, maxLoanIgnoreSupply);
        }

        if (currentLoanBalance >= maxLoanIgnoreSupply) {
            return (0, maxLoanIgnoreSupply);
        }

        maxLoan = maxLoanIgnoreSupply - currentLoanBalance;

        uint256 vaultAvailableSupply = maxUtilization - outstandingCapital;
        if (maxLoan > vaultAvailableSupply) {
            maxLoan = vaultAvailableSupply;
        }

        return (maxLoan, maxLoanIgnoreSupply);
    }

    /**
     * @dev Enforce collateral requirements
     */
    function enforceCollateralRequirements() external view returns (bool success) {
        ERC4626CollateralData storage data = _getStorage();
        if (data.overSuppliedVaultDebt > 0) {
            revert BadDebt(data.overSuppliedVaultDebt);
        }
        if (data.undercollateralizedDebt > 0) {
            revert UndercollateralizedDebt(data.undercollateralizedDebt);
        }
        return true;
    }

    function _updateUndercollateralizedDebt(
        ERC4626CollateralData storage data,
        uint256 previousMaxLoanIgnoreSupply,
        uint256 newMaxLoanIgnoreSupply
    ) internal {
        uint256 totalDebt = data.debt;

        bool isRemovingCollateral = previousMaxLoanIgnoreSupply > newMaxLoanIgnoreSupply;

        if (totalDebt <= newMaxLoanIgnoreSupply) {
            data.undercollateralizedDebt = 0;
            return;
        }

        uint256 difference;
        if (isRemovingCollateral) {
            difference = previousMaxLoanIgnoreSupply - newMaxLoanIgnoreSupply;
            data.undercollateralizedDebt += difference;
        } else {
            difference = newMaxLoanIgnoreSupply - previousMaxLoanIgnoreSupply;
            if (data.undercollateralizedDebt < difference) {
                data.undercollateralizedDebt = 0;
            } else {
                data.undercollateralizedDebt -= difference;
            }
        }
    }

    /**
     * @dev Add debt without borrowing (for migrations)
     */
    function addDebt(address portfolioAccountConfig, uint256 amount, uint256 unpaidFees) external {
        ERC4626CollateralData storage data = _getStorage();
        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        require(amount <= maxLoanIgnoreSupply, "Amount exceeds max loan");
        data.debt += amount;
        data.unpaidFees += unpaidFees;
    }

    /**
     * @dev Transfer debt away without payment
     */
    function transferDebtAway(address portfolioAccountConfig, uint256 amount, uint256 unpaidFees) external {
        ERC4626CollateralData storage data = _getStorage();

        (, uint256 previousMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        uint256 debtToTransfer = amount > data.debt ? data.debt : amount;

        if (debtToTransfer == 0) {
            return;
        }

        if (data.overSuppliedVaultDebt > 0) {
            uint256 overSuppliedToTransfer = data.overSuppliedVaultDebt > debtToTransfer
                ? debtToTransfer
                : data.overSuppliedVaultDebt;
            data.overSuppliedVaultDebt -= overSuppliedToTransfer;
        }

        uint256 feesToTransfer = unpaidFees > data.unpaidFees
            ? data.unpaidFees
            : unpaidFees;
        data.unpaidFees -= feesToTransfer;

        data.debt -= debtToTransfer;
        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioAccountConfig);
        _updateUndercollateralizedDebt(data, previousMaxLoanIgnoreSupply, newMaxLoanIgnoreSupply);
    }

    /**
     * @dev Remove shares for yield claiming without affecting depositedAssetValue
     * Used by ERC4626ClaimingFacet when harvesting yield
     * @param shares The shares to remove (representing yield)
     */
    function removeSharesForYield(uint256 shares) external {
        ERC4626CollateralData storage data = _getStorage();
        require(data.shares >= shares, "Insufficient shares");

        uint256 remainingShares = data.shares - shares;
        uint256 remainingValue = IERC4626(data.vault).convertToAssets(remainingShares);
        require(remainingValue >= data.depositedAssetValue, "Would remove principal");

        data.shares = remainingShares;
    }
}
