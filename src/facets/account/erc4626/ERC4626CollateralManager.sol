// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILoanConfig} from "../config/ILoanConfig.sol";
import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {ILendingVault} from "../../../interfaces/ILendingVault.sol";
import {PortfolioFactoryConfig} from "../config/PortfolioFactoryConfig.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../accounts/PortfolioManager.sol";


/**
 * @title ERC4626CollateralManager
 * @dev Library for managing ERC4626 vault shares as collateral
 * Handles share tracking, collateral value calculation, and debt management.
 * The vault address is NOT stored here — it is an immutable on each facet.
 * YieldBasis LP collateral is handled by YieldBasisCollateralManager, not here.
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
     * @dev Resolve the collateral value of vault shares via previewRedeem,
     *      the EIP-4626 primitive that simulates redemption at current on-chain
     *      conditions and includes any exit fee or under-delivery. A vault whose
     *      previewRedeem reverts (e.g. paused) halts borrow-side reads; repay
     *      paths are unaffected.
     */
    function _resolveCollateralValue(address vault, uint256 shares) internal view returns (uint256 value) {
        if (shares == 0 || vault == address(0)) return 0;
        return IERC4626(vault).previewRedeem(shares);
    }

    /**
     * @dev Add ERC4626 shares as collateral
     * @param portfolioFactoryConfig The portfolio account config address
     * @param vault The ERC4626 vault address (immutable on facet)
     * @param shares The amount of shares to add as collateral
     */
    function addCollateral(address portfolioFactoryConfig, address vault, uint256 shares) public {
        require(vault != address(0), "Invalid vault address");
        require(shares > 0, "Shares must be > 0");
        _snapshotIfNeeded(portfolioFactoryConfig, vault);
        ERC4626CollateralData storage data = _getStorage();

        uint256 requiredBalance = data.shares + shares;
        uint256 actualBalance = IERC20(vault).balanceOf(address(this));
        if (actualBalance < requiredBalance) {
            revert InsufficientShareBalance(requiredBalance, actualBalance);
        }

        uint256 assetValue = _resolveCollateralValue(vault, shares);

        data.shares += shares;
        data.depositedAssetValue += assetValue;

        emit ERC4626CollateralAdded(vault, shares, assetValue, address(this));
    }

    /**
     * @dev Remove ERC4626 shares from collateral
     */
    function removeCollateral(address portfolioFactoryConfig, address vault, uint256 shares) public {
        require(shares > 0, "Shares must be > 0");
        _snapshotIfNeeded(portfolioFactoryConfig, vault);

        ERC4626CollateralData storage data = _getStorage();
        require(data.shares >= shares, "Insufficient collateral shares");

        uint256 assetValueToRemove = (data.depositedAssetValue * shares) / data.shares;

        data.shares -= shares;
        data.depositedAssetValue -= assetValueToRemove;

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault);
        require(getTotalDebt() <= newMaxLoanIgnoreSupply, "Debt exceeds max loan");

        emit ERC4626CollateralRemoved(vault, shares, assetValueToRemove, address(this));
    }

    /**
     * @dev Get total collateral value in underlying assets
     */
    function getTotalCollateralValue(address vault) public view returns (uint256 totalValue) {
        ERC4626CollateralData storage data = _getStorage();
        totalValue = _resolveCollateralValue(vault, data.shares);
    }

    /**
     * @dev Get collateral info
     */
    function getCollateral(address vault) public view returns (
        uint256 shares,
        uint256 depositedAssetValue,
        uint256 currentAssetValue
    ) {
        ERC4626CollateralData storage data = _getStorage();
        shares = data.shares;
        depositedAssetValue = data.depositedAssetValue;
        currentAssetValue = _resolveCollateralValue(vault, shares);
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
    function increaseTotalDebt(address portfolioFactoryConfig, address vault, uint256 amount) public returns (uint256 loanAmount, uint256 originationFee) {
        _snapshotIfNeeded(portfolioFactoryConfig, vault);
        ERC4626CollateralData storage data = _getStorage();
        address factory = PortfolioFactoryConfig(portfolioFactoryConfig).getPortfolioFactory();
        PortfolioManager manager = PortfolioFactory(factory).portfolioManager();
        bool isAuthorizedCaller = manager.isAuthorizedCaller(msg.sender);
        if (msg.sender != address(manager) && !isAuthorizedCaller) revert NotPortfolioManager();
        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());

        // Pre-borrow supply-side check
        (uint256 maxLoan,) = getMaxLoan(portfolioFactoryConfig, vault);
        if (amount > maxLoan) {
            data.overSuppliedVaultDebt += amount - maxLoan;
        }

        originationFee = lendingPool.borrowFromPortfolio(amount);
        loanAmount = amount - originationFee;

        // Sync local debt with the vault's actual post-borrow debt balance.
        data.debt = lendingPool.getDebtBalance(address(this));

        // Authorized callers bypass PortfolioManager wrapper, so enforce inline
        if (isAuthorizedCaller) {
            enforceCollateralRequirements(portfolioFactoryConfig, vault);
        }

        return (loanAmount, originationFee);
    }

    /**
     * @dev Decrease total debt by paying to lending pool
     * @param portfolioFactoryConfig The portfolio account config address
     * @param vault The ERC4626 collateral vault address
     * @param amount The amount to pay
     * @return excess Any excess amount after fully paying debt
     */
    function decreaseTotalDebt(address portfolioFactoryConfig, address vault, uint256 amount) public returns (uint256 excess) {
        _snapshotIfNeeded(portfolioFactoryConfig, vault);
        return _decreaseTotalDebt(portfolioFactoryConfig, amount);
    }

    function _decreaseTotalDebt(address portfolioFactoryConfig, uint256 amount) internal returns (uint256 excess) {
        ERC4626CollateralData storage data = _getStorage();

        uint256 totalDebt = data.debt;
        uint256 balancePayment = totalDebt > amount ? amount : totalDebt;

        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());

        IERC20(lendingPool.lendingAsset()).forceApprove(address(lendingPool), balancePayment);
        uint256 actualPaid = lendingPool.payFromPortfolio(balancePayment, 0);
        IERC20(lendingPool.lendingAsset()).forceApprove(address(lendingPool), 0);

        excess = amount - actualPaid;

        // Sync local debt with vault's actual debt balance.
        // The vault may have implicitly reduced debt via reward settlement beyond the explicit payment.
        data.debt = lendingPool.getDebtBalance(address(this));

        // Decrement supply-side flag by what was actually paid, clamped at zero. Repays
        // must never revert, so we never read global state here to potentially raise the flag.
        uint256 prevOverSupplied = data.overSuppliedVaultDebt;
        if (prevOverSupplied > 0) {
            data.overSuppliedVaultDebt =
                prevOverSupplied > actualPaid ? prevOverSupplied - actualPaid : 0;
        }

        return excess;
    }

    /**
     * @dev Get the maximum loan amount based on collateral value
     */
    function getMaxLoan(address portfolioFactoryConfig, address vault) public view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        uint256 totalCollateralValue = getTotalCollateralValue(vault);
        ILoanConfig loanConfig = PortfolioFactoryConfig(portfolioFactoryConfig).getLoanConfig();

        uint256 ltv = loanConfig.getLtv();

        if (ltv == 0) {
            // Cash-flow path: operator calibrates rewardsRate*multiplier to bake in
            // periodic rate plus any cross-asset price. The 1e12 divisor absorbs
            // collateral-vs-lending-asset decimal scaling.
            uint256 rewardsRate = loanConfig.getRewardsRate();
            uint256 multiplier = loanConfig.getMultiplier();
            maxLoanIgnoreSupply = (((totalCollateralValue * rewardsRate) / 1000000) *
                multiplier) / 1e12;
        } else {
            // Like-to-like path. convertToAssets returns vault-asset native decimals;
            // for this branch to be correct the lending asset must match the vault asset.
            maxLoanIgnoreSupply = (totalCollateralValue * ltv) / 10000;
        }

        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());
        uint256 outstandingCapital = lendingPool.activeAssets();

        // Supply source: vault.totalAssets() (already accounts for vesting/escrowed liabilities).
        // Cap source: LoanConfig.getMaxUtilizationBps() (single home for the cap; vault no
        // longer enforces, only the manager-side overSuppliedVaultDebt flag does).
        uint256 vaultTotalAssets = ILendingVault(lendingPool.lendingVault()).totalAssets();
        uint256 maxUtilizationBps = loanConfig.getMaxUtilizationBps();

        uint256 currentLoanBalance = getTotalDebt();

        return _calculateMaxLoan(maxLoanIgnoreSupply, vaultTotalAssets, outstandingCapital, currentLoanBalance, maxUtilizationBps);
    }

    function _calculateMaxLoan(
        uint256 maxLoanIgnoreSupply,
        uint256 vaultTotalAssets,
        uint256 outstandingCapital,
        uint256 currentLoanBalance,
        uint256 maxUtilizationBps
    ) internal pure returns (uint256 maxLoan, uint256 maxLoanIgnoreSupplyOut) {
        maxLoanIgnoreSupplyOut = maxLoanIgnoreSupply;

        uint256 maxUtilization = (vaultTotalAssets * maxUtilizationBps) / 10000;

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

    /// @dev Returns per-borrower LTV in bps: 0 = no debt, 100_00 = at LTV limit, >100_00 = underwater.
    function getLoanUtilization(address portfolioFactoryConfig, address vault) public view returns (uint256) {
        uint256 totalDebt = getTotalDebt();
        if (totalDebt == 0) return 0;

        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault);
        if (maxLoanIgnoreSupply == 0) return type(uint256).max;

        return (totalDebt * 100_00) / maxLoanIgnoreSupply;
    }

    /**
     * @dev Compute the current shortfall: how much debt exceeds maxLoanIgnoreSupply.
     */
    function _currentShortfall(address portfolioFactoryConfig, address vault) internal view returns (uint256) {
        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault);
        uint256 debt = getTotalDebt();
        return debt > maxLoanIgnoreSupply ? debt - maxLoanIgnoreSupply : 0;
    }

    /**
     * @dev Snapshot the shortfall at the start of the first mutating call in this block.
     */
    function snapshotShortfall(address portfolioFactoryConfig, address vault) public {
        _snapshotIfNeeded(portfolioFactoryConfig, vault);
    }

    /**
     * @dev Enforce collateral requirements using snapshot comparison.
     */
    function enforceCollateralRequirements(address portfolioFactoryConfig, address vault) public view returns (bool) {
        ERC4626CollateralData storage data = _getStorage();

        uint256 end = _currentShortfall(portfolioFactoryConfig, vault);

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

    function _syncDebt(address portfolioFactoryConfig) internal {
        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());
        _getStorage().debt = lendingPool.getDebtBalance(address(this));
    }

    function _snapshotIfNeeded(address portfolioFactoryConfig, address vault) internal {
        _syncDebt(portfolioFactoryConfig);
        ERC4626CollateralData storage data = _getStorage();
        if (data.snapshotBlockNumber != block.number) {
            data.snapshotBlockNumber = block.number;
            data.startShortfall = _currentShortfall(portfolioFactoryConfig, vault);
        }
    }

    /**
     * @dev Remove shares for yield claiming without affecting depositedAssetValue.
     *      Gated by isAuthorizedCaller. The PortfolioManager is intentionally NOT
     *      bypassed — it does not call this path. An unauthorized caller could
     *      otherwise burn share tracking without burning real shares and unlock
     *      fictitious borrow capacity.
     */
    function removeSharesForYield(address portfolioFactoryConfig, address vault, uint256 shares) public {
        _snapshotIfNeeded(portfolioFactoryConfig, vault);

        address factory = PortfolioFactoryConfig(portfolioFactoryConfig).getPortfolioFactory();
        require(
            PortfolioFactory(factory).portfolioManager().isAuthorizedCaller(msg.sender),
            "Unauthorized"
        );

        ERC4626CollateralData storage data = _getStorage();
        require(data.shares >= shares, "Insufficient shares");

        uint256 remainingShares = data.shares - shares;
        uint256 remainingValue = _resolveCollateralValue(vault, remainingShares);
        require(remainingValue >= data.depositedAssetValue, "Would remove principal");

        data.shares = remainingShares;

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault);
        require(getTotalDebt() <= newMaxLoanIgnoreSupply, "Debt exceeds max loan");
    }
}
