// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILoanConfig} from "../config/ILoanConfig.sol";
import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {ILendingVault} from "../../../interfaces/ILendingVault.sol";
import {PortfolioFactoryConfig} from "../config/PortfolioFactoryConfig.sol";
import {IERC4626CollateralVaultConfig} from "./ERC4626PortfolioFactoryConfig.sol";
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
    error BelowMinimumCollateral(uint256 remaining, uint256 minimum);
    error VaultMismatch(address stored, address provided);

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
     *      conditions and includes any exit fee or under-delivery. revertOnFail
     *      governs a reverting previewRedeem (e.g. paused vault): borrow-side
     *      reads pass true and re-bubble the revert; the repay path passes false
     *      and gets ok=false so it can skip the shortfall snapshot instead of
     *      blocking debt reduction.
     */
    function _resolveCollateralValue(address vault, uint256 shares, bool revertOnFail) internal view returns (uint256 value, bool ok) {
        if (shares == 0 || vault == address(0)) return (0, true);
        try IERC4626(vault).previewRedeem(shares) returns (uint256 v) {
            return (v, true);
        } catch (bytes memory reason) {
            if (revertOnFail) {
                assembly { revert(add(reason, 0x20), mload(reason)) }
            }
            return (0, false);
        }
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

        (uint256 assetValue, ) = _resolveCollateralValue(vault, shares, true);

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

        // Disallow leaving a dust position below the configured minimum; a full exit is allowed.
        uint256 remaining = getTotalCollateralValue(vault);
        uint256 minimum = PortfolioFactoryConfig(portfolioFactoryConfig).getMinimumCollateral();
        if (remaining != 0 && remaining < minimum) revert BelowMinimumCollateral(remaining, minimum);

        emit ERC4626CollateralRemoved(vault, shares, assetValueToRemove, address(this));
    }

    /**
     * @dev Get total collateral value in underlying assets
     */
    function getTotalCollateralValue(address vault) public view returns (uint256 totalValue) {
        ERC4626CollateralData storage data = _getStorage();
        (totalValue, ) = _resolveCollateralValue(vault, data.shares, true);
    }

    /// @dev Borrow/health basis: appreciation above cost basis is reserved for
    ///      yield, so cap at min(depositedAssetValue, current). Falls to current
    ///      on depreciation so health still reacts to losses.
    function getBorrowableCollateralValue(address vault) internal view returns (uint256) {
        uint256 current = getTotalCollateralValue(vault);
        uint256 basis = _getStorage().depositedAssetValue;
        return current < basis ? current : basis;
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
        (currentAssetValue, ) = _resolveCollateralValue(vault, shares, true);
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
        _snapshotIfNeededRepay(portfolioFactoryConfig, vault);
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

    /// @dev maxLoanIgnoreSupply from a collateral value. Single source of truth
    ///      shared by getMaxLoan and the repay-path shortfall computation.
    function _maxLoanIgnoreSupply(address portfolioFactoryConfig, uint256 totalCollateralValue) internal view returns (uint256 maxLoanIgnoreSupply) {
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
    }

    /**
     * @dev Get the maximum loan amount based on collateral value
     */
    function getMaxLoan(address portfolioFactoryConfig, address vault) public view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        uint256 totalCollateralValue = getBorrowableCollateralValue(vault);
        ILoanConfig loanConfig = PortfolioFactoryConfig(portfolioFactoryConfig).getLoanConfig();

        maxLoanIgnoreSupply = _maxLoanIgnoreSupply(portfolioFactoryConfig, totalCollateralValue);

        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());
        uint256 outstandingCapital = lendingPool.activeAssets();

        // Supply source: vault.totalAssets() (already accounts for vesting/escrowed liabilities).
        // Cap source: LoanConfig.getMaxUtilizationBps() (single home for the cap; vault no
        // longer enforces, only the manager-side overSuppliedVaultDebt flag does).
        uint256 vaultTotalAssets = ILendingVault(lendingPool.lendingVault()).borrowableTotalAssets();
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

    /// @dev Revert if the facet vault disagrees with the set-once canonical vault in config; skipped while unset.
    function _enforceVault(address portfolioFactoryConfig, address vault) internal view {
        address canonical = IERC4626CollateralVaultConfig(portfolioFactoryConfig).getCollateralVault();
        if (canonical != address(0) && canonical != vault) revert VaultMismatch(canonical, vault);
    }

    function _snapshotIfNeeded(address portfolioFactoryConfig, address vault) internal {
        _enforceVault(portfolioFactoryConfig, vault);
        _syncDebt(portfolioFactoryConfig);
        ERC4626CollateralData storage data = _getStorage();
        if (data.snapshotBlockNumber != block.number) {
            data.snapshotBlockNumber = block.number;
            data.startShortfall = _currentShortfall(portfolioFactoryConfig, vault);
        }
    }

    /// @dev Repay-path snapshot. Always syncs debt; records the shortfall baseline
    ///      only if the collateral read succeeds. A paused collateral vault skips
    ///      the snapshot instead of blocking the repay; a later borrow-side op in
    ///      the same block re-attempts the strict read and still reverts.
    function _snapshotIfNeededRepay(address portfolioFactoryConfig, address vault) internal {
        _syncDebt(portfolioFactoryConfig);
        ERC4626CollateralData storage data = _getStorage();
        if (data.snapshotBlockNumber == block.number) return;
        (uint256 collateralValue, bool ok) = _resolveCollateralValue(vault, data.shares, false);
        if (!ok) return;
        // Mirror getBorrowableCollateralValue: cap at cost basis so the repay
        // baseline matches the borrow-side shortfall computation.
        uint256 basis = data.depositedAssetValue;
        uint256 borrowable = collateralValue < basis ? collateralValue : basis;
        uint256 maxLoanIgnoreSupply = _maxLoanIgnoreSupply(portfolioFactoryConfig, borrowable);
        uint256 debt = getTotalDebt();
        data.snapshotBlockNumber = block.number;
        data.startShortfall = debt > maxLoanIgnoreSupply ? debt - maxLoanIgnoreSupply : 0;
    }

    /**
     * @dev Reduce tracked shares to reflect harvested yield, holding
     *      depositedAssetValue fixed. Accounting only; the paired share redeem
     *      lives in the claiming facet. Three checks bound any caller: remaining
     *      value must still cover depositedAssetValue (no principal removal), the
     *      fixed basis blocks re-harvesting principal as fake yield, and debt must
     *      stay within max-loan. isAuthorizedCaller-gated; a standalone call can
     *      only desync tracking downward, which addCollateral re-syncs.
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
        (uint256 remainingValue, ) = _resolveCollateralValue(vault, remainingShares, true);
        require(remainingValue >= data.depositedAssetValue, "Would remove principal");

        data.shares = remainingShares;

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault);
        require(getTotalDebt() <= newMaxLoanIgnoreSupply, "Debt exceeds max loan");
    }
}
