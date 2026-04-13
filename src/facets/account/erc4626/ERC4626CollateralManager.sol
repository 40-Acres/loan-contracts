// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILoanConfig} from "../config/ILoanConfig.sol";
import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {PortfolioFactoryConfig} from "../config/PortfolioFactoryConfig.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../accounts/PortfolioManager.sol";
import {IYieldBasisLP} from "../../../interfaces/IYieldBasisLP.sol";

interface IERC4626DebtBalanceReader {
    function getDebtBalance(address borrower) external view returns (uint256);
}


/**
 * @title ERC4626CollateralManager
 * @dev Library for managing ERC4626 vault shares as collateral
 * Handles share tracking, collateral value calculation, and debt management.
 * The vault address is NOT stored here — it is an immutable on each facet.
 */
library ERC4626CollateralManager {
    using SafeERC20 for IERC20;

    error InsufficientCollateral();
    error BadDebt(uint256 debt);
    error UndercollateralizedDebt(uint256 debt);
    error NotPortfolioManager();
    error InsufficientShareBalance(uint256 required, uint256 actual);

    event ERC4626CollateralAdded(address indexed vault, uint256 shares, uint256 assetValue, address indexed owner);
    event ERC4626CollateralRemoved(address indexed vault, uint256 shares, uint256 assetValue, address indexed owner);

    struct ERC4626CollateralData {
        uint256 shares;              // Shares deposited as collateral
        uint256 depositedAssetValue; // Asset value at time of deposit (for tracking)
        // Debt tracking
        uint256 debt;
        uint256 overSuppliedVaultDebt;
        uint256 startShortfall; // overwrites deprecated undercollateralizedDebt slot
        uint256 snapshotBlockNumber;
    }

    bytes32 private constant STORAGE_POSITION = keccak256("storage.ERC4626CollateralManager");

    function _getStorage() internal pure returns (ERC4626CollateralData storage data) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            data.slot := position
        }
    }

    /**
     * @dev Resolve the collateral value of vault shares, optionally applying LP pricePerShare conversion.
     * @param vault The ERC4626 vault (e.g. gauge) address
     * @param lpToken If non-zero, apply two-layer pricing: vault shares → LP tokens → underlying via pricePerShare()
     * @param shares The amount of vault shares to value
     * @return value The collateral value in underlying asset units
     */
    /**
     * @dev Resolve the collateral value of vault shares.
     * When lpToken == address(0): standard ERC4626 — returns vault.convertToAssets(shares).
     * When lpToken != address(0): two-layer pricing — gauge shares → LP tokens → underlying
     *   via LP pricePerShare(). Result is in 18 decimals (LP-native precision).
     */
    function _resolveCollateralValue(address vault, address lpToken, uint256 shares) internal view returns (uint256 value) {
        if (shares == 0 || vault == address(0)) return 0;
        uint256 lpAmount = IERC4626(vault).convertToAssets(shares);
        if (lpToken == address(0)) return lpAmount;
        // Two-layer: LP amount × pricePerShare / 1e18 → underlying value (18 decimals)
        uint256 pps = IYieldBasisLP(lpToken).pricePerShare();
        return (lpAmount * pps) / 1e18;
    }

    /**
     * @dev Add ERC4626 shares as collateral
     * @param portfolioFactoryConfig The portfolio account config address
     * @param vault The ERC4626 vault address (immutable on facet)
     * @param shares The amount of shares to add as collateral
     */
    function addCollateral(address portfolioFactoryConfig, address vault, uint256 shares) external {
        addCollateral(portfolioFactoryConfig, vault, address(0), shares);
    }

    /**
     * @dev Add ERC4626 shares as collateral with optional LP pricing
     * @param portfolioFactoryConfig The portfolio account config address
     * @param vault The ERC4626 vault address (immutable on facet)
     * @param lpToken If non-zero, value shares using LP pricePerShare for underlying asset pricing
     * @param shares The amount of shares to add as collateral
     */
    function addCollateral(address portfolioFactoryConfig, address vault, address lpToken, uint256 shares) public {
        require(vault != address(0), "Invalid vault address");
        require(shares > 0, "Shares must be > 0");
        _snapshotIfNeeded(portfolioFactoryConfig, vault, lpToken);
        ERC4626CollateralData storage data = _getStorage();

        // Ensure the portfolio actually holds the shares being registered.
        // When lpToken is set (YB mode), some shares may be unstaked as LP tokens
        // on the portfolio directly — count both gauge shares and LP token balance.
        uint256 requiredBalance = data.shares + shares;
        uint256 actualBalance = IERC20(vault).balanceOf(address(this));
        if (lpToken != address(0)) {
            // LP tokens held directly are equivalent to gauge shares for balance purposes
            uint256 lpBalance = IERC20(lpToken).balanceOf(address(this));
            uint256 equivalentShares = lpBalance > 0 ? IERC4626(vault).convertToShares(lpBalance) : 0;
            actualBalance += equivalentShares;
        }
        if (actualBalance < requiredBalance) {
            revert InsufficientShareBalance(requiredBalance, actualBalance);
        }

        // Calculate asset value of shares (underlying value if lpToken provided)
        uint256 assetValue = _resolveCollateralValue(vault, lpToken, shares);

        data.shares += shares;
        data.depositedAssetValue += assetValue;

        emit ERC4626CollateralAdded(vault, shares, assetValue, address(this));
    }

    /**
     * @dev Remove ERC4626 shares from collateral
     */
    function removeCollateral(address portfolioFactoryConfig, address vault, uint256 shares) external {
        removeCollateral(portfolioFactoryConfig, vault, address(0), shares);
    }

    /**
     * @dev Remove ERC4626 shares from collateral with optional LP pricing
     */
    function removeCollateral(address portfolioFactoryConfig, address vault, address lpToken, uint256 shares) public {
        require(shares > 0, "Shares must be > 0");
        _snapshotIfNeeded(portfolioFactoryConfig, vault, lpToken);

        ERC4626CollateralData storage data = _getStorage();
        require(data.shares >= shares, "Insufficient collateral shares");

        // Calculate proportional asset value to remove
        uint256 assetValueToRemove = (data.depositedAssetValue * shares) / data.shares;

        data.shares -= shares;
        data.depositedAssetValue -= assetValueToRemove;

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault, lpToken);
        require(data.debt <= newMaxLoanIgnoreSupply, "Debt exceeds max loan");

        emit ERC4626CollateralRemoved(vault, shares, assetValueToRemove, address(this));
    }

    /**
     * @dev Get total collateral value in underlying assets
     */
    function getTotalCollateralValue(address vault) public view returns (uint256 totalValue) {
        return getTotalCollateralValue(vault, address(0));
    }

    /**
     * @dev Get total collateral value with optional LP pricing
     */
    function getTotalCollateralValue(address vault, address lpToken) public view returns (uint256 totalValue) {
        ERC4626CollateralData storage data = _getStorage();
        totalValue = _resolveCollateralValue(vault, lpToken, data.shares);
    }

    /**
     * @dev Get collateral info
     */
    function getCollateral(address vault) external view returns (
        uint256 shares,
        uint256 depositedAssetValue,
        uint256 currentAssetValue
    ) {
        return getCollateral(vault, address(0));
    }

    /**
     * @dev Get collateral info with optional LP pricing
     */
    function getCollateral(address vault, address lpToken) public view returns (
        uint256 shares,
        uint256 depositedAssetValue,
        uint256 currentAssetValue
    ) {
        ERC4626CollateralData storage data = _getStorage();
        shares = data.shares;
        depositedAssetValue = data.depositedAssetValue;
        currentAssetValue = _resolveCollateralValue(vault, lpToken, shares);
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
     * @dev Increase total debt by borrowing from lending pool
     * @param portfolioFactoryConfig The portfolio account config address
     * @param vault The ERC4626 collateral vault address
     * @param amount The amount to borrow
     * @return loanAmount The actual loan amount after fees
     * @return originationFee The origination fee
     */
    function increaseTotalDebt(address portfolioFactoryConfig, address vault, uint256 amount) external returns (uint256 loanAmount, uint256 originationFee) {
        return increaseTotalDebt(portfolioFactoryConfig, vault, address(0), amount);
    }

    function increaseTotalDebt(address portfolioFactoryConfig, address vault, address lpToken, uint256 amount) public returns (uint256 loanAmount, uint256 originationFee) {
        _snapshotIfNeeded(portfolioFactoryConfig, vault, lpToken);
        ERC4626CollateralData storage data = _getStorage();
        // Ensure debt can only be increased via PortfolioManager multicall or authorized callers
        address factory = PortfolioFactoryConfig(portfolioFactoryConfig).getPortfolioFactory();
        PortfolioManager manager = PortfolioFactory(factory).portfolioManager();
        if (msg.sender != address(manager) && !manager.isAuthorizedCaller(msg.sender)) revert NotPortfolioManager();
        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());

        (uint256 maxLoan,) = getMaxLoan(portfolioFactoryConfig, vault, lpToken);

        if (amount > maxLoan) {
            data.overSuppliedVaultDebt += amount - maxLoan;
        }

        data.debt += amount;
        originationFee = lendingPool.borrowFromPortfolio(amount);
        loanAmount = amount - originationFee;
        return (loanAmount, originationFee);
    }

    /**
     * @dev Decrease total debt by paying to lending pool
     * @param portfolioFactoryConfig The portfolio account config address
     * @param vault The ERC4626 collateral vault address
     * @param amount The amount to pay
     * @return excess Any excess amount after fully paying debt
     */
    function decreaseTotalDebt(address portfolioFactoryConfig, address vault, uint256 amount) external returns (uint256 excess) {
        return decreaseTotalDebt(portfolioFactoryConfig, vault, address(0), amount);
    }

    function decreaseTotalDebt(address portfolioFactoryConfig, address vault, address lpToken, uint256 amount) public returns (uint256 excess) {
        _snapshotIfNeeded(portfolioFactoryConfig, vault, lpToken);
        return _decreaseTotalDebt(portfolioFactoryConfig, vault, lpToken, amount);
    }

    function _decreaseTotalDebt(address portfolioFactoryConfig, address vault, address lpToken, uint256 amount) internal returns (uint256 excess) {
        ERC4626CollateralData storage data = _getStorage();

        uint256 totalDebt = data.debt;
        uint256 balancePayment = totalDebt > amount ? amount : totalDebt;

        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());

        IERC20(lendingPool.lendingAsset()).approve(address(lendingPool), balancePayment);
        uint256 actualPaid = lendingPool.payFromPortfolio(balancePayment, 0);
        IERC20(lendingPool.lendingAsset()).approve(address(lendingPool), 0);

        excess = amount - actualPaid;

        // Sync local debt with vault's actual debt balance.
        // The vault may have implicitly reduced debt via reward settlement beyond the explicit payment.
        data.debt = IERC4626DebtBalanceReader(address(lendingPool)).getDebtBalance(address(this));

        if (data.overSuppliedVaultDebt > 0) {
            data.overSuppliedVaultDebt -= data.overSuppliedVaultDebt > actualPaid ? actualPaid : data.overSuppliedVaultDebt;
        }

        return excess;
    }

    /**
     * @dev Get the maximum loan amount based on collateral value
     */
    function getMaxLoan(address portfolioFactoryConfig, address vault) public view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        return getMaxLoan(portfolioFactoryConfig, vault, address(0));
    }

    /**
     * @dev Get the maximum loan amount with optional LP pricing
     */
    function getMaxLoan(address portfolioFactoryConfig, address vault, address lpToken) public view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        uint256 totalCollateralValue = getTotalCollateralValue(vault, lpToken);
        ILoanConfig loanConfig = PortfolioFactoryConfig(portfolioFactoryConfig).getLoanConfig();

        // Get loan-to-value ratio (LTV) from multiplier - e.g., 7000 = 70%
        uint256 ltv = loanConfig.getMultiplier();

        // Calculate max loan based on collateral value and LTV
        maxLoanIgnoreSupply = (totalCollateralValue * ltv) / 10000;

        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());
        uint256 outstandingCapital = lendingPool.activeAssets();

        address lendingVault = lendingPool.lendingVault();
        IERC4626 vaultAsset = IERC4626(lendingVault);
        address underlyingAsset = vaultAsset.asset();
        uint256 vaultBalance = IERC20(underlyingAsset).balanceOf(lendingVault);

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

    function getLTVRatio(address portfolioFactoryConfig, address vault) public view returns (uint256) {
        return getLTVRatio(portfolioFactoryConfig, vault, address(0));
    }

    function getLTVRatio(address portfolioFactoryConfig, address vault, address lpToken) public view returns (uint256) {
        uint256 totalDebt = getTotalDebt();
        if (totalDebt == 0) return 0;

        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault, lpToken);
        if (maxLoanIgnoreSupply == 0) return type(uint256).max;

        return (totalDebt * 100) / maxLoanIgnoreSupply;
    }

    /**
     * @dev Compute the current shortfall: how much debt exceeds maxLoanIgnoreSupply.
     */
    function _currentShortfall(address portfolioFactoryConfig, address vault, address lpToken) internal view returns (uint256) {
        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault, lpToken);
        uint256 debt = getTotalDebt();
        return debt > maxLoanIgnoreSupply ? debt - maxLoanIgnoreSupply : 0;
    }

    /**
     * @dev Snapshot the shortfall at the start of the first mutating call in this block.
     */
    function snapshotShortfall(address portfolioFactoryConfig, address vault) external {
        snapshotShortfall(portfolioFactoryConfig, vault, address(0));
    }

    function snapshotShortfall(address portfolioFactoryConfig, address vault, address lpToken) public {
        ERC4626CollateralData storage data = _getStorage();
        if (data.snapshotBlockNumber != block.number) {
            data.snapshotBlockNumber = block.number;
            data.startShortfall = _currentShortfall(portfolioFactoryConfig, vault, lpToken);
        }
    }

    /**
     * @dev Enforce collateral requirements using snapshot comparison.
     */
    function enforceCollateralRequirements(address portfolioFactoryConfig, address vault) external view returns (bool) {
        return enforceCollateralRequirements(portfolioFactoryConfig, vault, address(0));
    }

    function enforceCollateralRequirements(address portfolioFactoryConfig, address vault, address lpToken) public view returns (bool) {
        ERC4626CollateralData storage data = _getStorage();

        uint256 end = _currentShortfall(portfolioFactoryConfig, vault, lpToken);

        // If a snapshot was taken this block, use it as the baseline.
        // Otherwise no collateral/debt operation ran, so start == end (no change).
        uint256 start = (data.snapshotBlockNumber == block.number)
            ? data.startShortfall
            : end;

        if (end > start) {
            revert UndercollateralizedDebt(end - start);
        }

        if (data.overSuppliedVaultDebt > 0) {
            revert BadDebt(data.overSuppliedVaultDebt);
        }

        return true;
    }

    function _snapshotIfNeeded(address portfolioFactoryConfig, address vault, address lpToken) internal {
        ERC4626CollateralData storage data = _getStorage();
        if (data.snapshotBlockNumber != block.number) {
            data.snapshotBlockNumber = block.number;
            data.startShortfall = _currentShortfall(portfolioFactoryConfig, vault, lpToken);
        }
    }

    /**
     * @dev Remove shares for yield claiming without affecting depositedAssetValue
     */
    function removeSharesForYield(address portfolioFactoryConfig, address vault, uint256 shares) external {
        removeSharesForYield(portfolioFactoryConfig, vault, address(0), shares);
    }

    function removeSharesForYield(address portfolioFactoryConfig, address vault, address lpToken, uint256 shares) public {
        _snapshotIfNeeded(portfolioFactoryConfig, vault, lpToken);
        ERC4626CollateralData storage data = _getStorage();
        require(data.shares >= shares, "Insufficient shares");

        uint256 remainingShares = data.shares - shares;
        uint256 remainingValue = _resolveCollateralValue(vault, lpToken, remainingShares);
        require(remainingValue >= data.depositedAssetValue, "Would remove principal");

        data.shares = remainingShares;

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault, lpToken);
        require(data.debt <= newMaxLoanIgnoreSupply, "Debt exceeds max loan");
    }
}
