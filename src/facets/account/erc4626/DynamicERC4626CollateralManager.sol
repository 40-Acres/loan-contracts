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
 * @title DynamicERC4626CollateralManager
 * @dev ERC4626 vault-share collateral manager for lending pools that keep
 *      per-borrower debt in their own storage and may mutate it independently
 *      of borrow/pay calls (e.g. reward streaming that auto-decrements debt).
 *
 *      Debt is never cached. Every read fetches from the pool via
 *      `getDebtBalance` (raw) or `getEffectiveDebtBalance` (raw minus pending
 *      reward credits not yet settled). Solvency reverts use raw debt; headroom
 *      and utilization views use effective debt. Mirrors
 *      DynamicYieldBasisCollateralManager; collateral valuation uses
 *      previewRedeem like the cached ERC4626CollateralManager.
 *
 *      Uses its own storage slot, distinct from ERC4626CollateralManager, so the
 *      cached-debt and live-read variants install on different diamonds without
 *      slot collision.
 */
library DynamicERC4626CollateralManager {
    using SafeERC20 for IERC20;

    error InsufficientCollateral();
    error BadDebt(uint256 debt);
    error UndercollateralizedDebt(uint256 debt);
    error NotPortfolioManager();
    error InsufficientShareBalance(uint256 required, uint256 actual);
    error BelowMinimumCollateral(uint256 remaining, uint256 minimum);

    event ERC4626CollateralAdded(address indexed vault, uint256 shares, uint256 assetValue, address indexed owner);
    event ERC4626CollateralRemoved(address indexed vault, uint256 shares, uint256 assetValue, address indexed owner);

    struct DynamicERC4626CollateralData {
        uint256 shares;
        uint256 depositedAssetValue;
        uint256 overSuppliedVaultDebt;
        uint256 startShortfall;
        uint256 snapshotBlockNumber;
    }

    bytes32 private constant STORAGE_POSITION = keccak256("storage.DynamicERC4626CollateralManager");

    function _getStorage() internal pure returns (DynamicERC4626CollateralData storage data) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            data.slot := position
        }
    }

    /**
     * @dev Resolve the collateral value of vault shares via previewRedeem, which
     *      includes any exit fee or under-delivery. A vault whose previewRedeem
     *      reverts (e.g. paused) halts borrow-side reads; repay paths are
     *      unaffected because they never read collateral value.
     */
    function _resolveCollateralValue(address vault, uint256 shares) internal view returns (uint256 value) {
        if (shares == 0 || vault == address(0)) return 0;
        return IERC4626(vault).previewRedeem(shares);
    }

    function addCollateral(address portfolioFactoryConfig, address vault, uint256 shares) public {
        require(vault != address(0), "Invalid vault address");
        require(shares > 0, "Shares must be > 0");
        _snapshotIfNeeded(portfolioFactoryConfig, vault);
        DynamicERC4626CollateralData storage data = _getStorage();

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

    function removeCollateral(address portfolioFactoryConfig, address vault, uint256 shares) public {
        require(shares > 0, "Shares must be > 0");
        _snapshotIfNeeded(portfolioFactoryConfig, vault);

        DynamicERC4626CollateralData storage data = _getStorage();
        require(data.shares >= shares, "Insufficient collateral shares");

        uint256 assetValueToRemove = (data.depositedAssetValue * shares) / data.shares;

        data.shares -= shares;
        data.depositedAssetValue -= assetValueToRemove;

        // Solvency revert uses raw debt: a borrower's pending reward credit may
        // unwind if the stream is interrupted, so collateral release is gated by
        // the actually-owed balance, not the optimistic effective view.
        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault);
        require(getTotalDebt(portfolioFactoryConfig) <= newMaxLoanIgnoreSupply, "Debt exceeds max loan");

        // Disallow leaving a dust position below the configured minimum; a full exit is allowed.
        uint256 remaining = getTotalCollateralValue(vault);
        uint256 minimum = PortfolioFactoryConfig(portfolioFactoryConfig).getMinimumCollateral();
        if (remaining != 0 && remaining < minimum) revert BelowMinimumCollateral(remaining, minimum);

        emit ERC4626CollateralRemoved(vault, shares, assetValueToRemove, address(this));
    }

    function getTotalCollateralValue(address vault) public view returns (uint256 totalValue) {
        DynamicERC4626CollateralData storage data = _getStorage();
        totalValue = _resolveCollateralValue(vault, data.shares);
    }

    /// @dev Borrow/health basis: appreciation above cost basis is reserved for
    ///      yield, so cap at min(depositedAssetValue, current). Falls to current
    ///      on depreciation so health still reacts to losses.
    function getBorrowableCollateralValue(address vault) internal view returns (uint256) {
        uint256 current = getTotalCollateralValue(vault);
        uint256 basis = _getStorage().depositedAssetValue;
        return current < basis ? current : basis;
    }

    function getCollateral(address vault) public view returns (
        uint256 shares,
        uint256 depositedAssetValue,
        uint256 currentAssetValue
    ) {
        DynamicERC4626CollateralData storage data = _getStorage();
        shares = data.shares;
        depositedAssetValue = data.depositedAssetValue;
        currentAssetValue = _resolveCollateralValue(vault, shares);
    }

    function getCollateralShares() external view returns (uint256) {
        return _getStorage().shares;
    }

    /// @notice Raw outstanding debt. Use for solvency reverts.
    function getTotalDebt(address portfolioFactoryConfig) public view returns (uint256) {
        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());
        return lendingPool.getDebtBalance(address(this));
    }

    /// @notice Raw debt minus pending reward credits not yet settled. Use for
    ///         headroom and utilization views. Invariant: <= getTotalDebt().
    function getEffectiveTotalDebt(address portfolioFactoryConfig) public view returns (uint256) {
        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());
        return lendingPool.getEffectiveDebtBalance(address(this));
    }

    function increaseTotalDebt(address portfolioFactoryConfig, address vault, uint256 amount) public returns (uint256 loanAmount, uint256 originationFee) {
        _snapshotIfNeeded(portfolioFactoryConfig, vault);
        DynamicERC4626CollateralData storage data = _getStorage();
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

        // Authorized callers bypass PortfolioManager wrapper, so enforce inline
        if (isAuthorizedCaller) {
            enforceCollateralRequirements(portfolioFactoryConfig, vault);
        }

        return (loanAmount, originationFee);
    }

    function decreaseTotalDebt(address portfolioFactoryConfig, address vault, uint256 amount) public returns (uint256 excess) {
        _snapshotIfNeeded(portfolioFactoryConfig, vault);
        DynamicERC4626CollateralData storage data = _getStorage();

        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());

        // Read raw debt live, then size the payment to it. The pool may decrement
        // debt during payFromPortfolio via its internal vesting/settlement, so we
        // clamp to the pre-call value to avoid over-paying past the outstanding balance.
        uint256 totalDebt = lendingPool.getDebtBalance(address(this));
        uint256 balancePayment = totalDebt > amount ? amount : totalDebt;

        IERC20(lendingPool.lendingAsset()).forceApprove(address(lendingPool), balancePayment);
        uint256 actualPaid = lendingPool.payFromPortfolio(balancePayment, 0);
        IERC20(lendingPool.lendingAsset()).forceApprove(address(lendingPool), 0);

        excess = amount - actualPaid;

        // Decrement supply-side flag by what was actually paid, clamped at zero. Repays
        // must never revert, so we never read global state here to potentially raise the flag.
        uint256 prevOverSupplied = data.overSuppliedVaultDebt;
        if (prevOverSupplied > 0) {
            data.overSuppliedVaultDebt =
                prevOverSupplied > actualPaid ? prevOverSupplied - actualPaid : 0;
        }

        return excess;
    }

    function getMaxLoan(address portfolioFactoryConfig, address vault) public view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        uint256 totalCollateralValue = getBorrowableCollateralValue(vault);
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
            // Like-to-like path. previewRedeem returns vault-asset native decimals;
            // for this branch to be correct the lending asset must match the vault asset.
            maxLoanIgnoreSupply = (totalCollateralValue * ltv) / 10000;
        }

        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());
        uint256 outstandingCapital = lendingPool.activeAssets();

        uint256 vaultTotalAssets = ILendingVault(lendingPool.lendingVault()).totalAssets();
        uint256 maxUtilizationBps = loanConfig.getMaxUtilizationBps();

        // Headroom uses effective debt: surfaces in-flight reward credit so available
        // capacity reflects the stream before the next settlement call.
        uint256 currentLoanBalance = lendingPool.getEffectiveDebtBalance(address(this));

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

    /// @dev Returns per-borrower LTV in bps using effective debt: 0 = no debt,
    ///      100_00 = at LTV limit, >100_00 = underwater. UX value, not a solvency
    ///      gate -- enforceCollateralRequirements uses raw debt.
    function getLoanUtilization(address portfolioFactoryConfig, address vault) public view returns (uint256) {
        uint256 totalDebt = getEffectiveTotalDebt(portfolioFactoryConfig);
        if (totalDebt == 0) return 0;

        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault);
        if (maxLoanIgnoreSupply == 0) return type(uint256).max;

        return (totalDebt * 100_00) / maxLoanIgnoreSupply;
    }

    function _currentShortfall(address portfolioFactoryConfig, address vault) internal view returns (uint256) {
        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault);
        // Solvency shortfall uses raw debt. Pending reward credits do not discount
        // the borrower's actual owed balance until settled.
        uint256 debt = getTotalDebt(portfolioFactoryConfig);
        return debt > maxLoanIgnoreSupply ? debt - maxLoanIgnoreSupply : 0;
    }

    function snapshotShortfall(address portfolioFactoryConfig, address vault) public {
        _snapshotIfNeeded(portfolioFactoryConfig, vault);
    }

    function enforceCollateralRequirements(address portfolioFactoryConfig, address vault) public view returns (bool) {
        DynamicERC4626CollateralData storage data = _getStorage();

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

    function _snapshotIfNeeded(address portfolioFactoryConfig, address vault) internal {
        DynamicERC4626CollateralData storage data = _getStorage();
        if (data.snapshotBlockNumber != block.number) {
            data.snapshotBlockNumber = block.number;
            data.startShortfall = _currentShortfall(portfolioFactoryConfig, vault);
        }
    }

    /**
     * @dev Remove shares for yield claiming without affecting depositedAssetValue.
     *      Gated by isAuthorizedCaller. The PortfolioManager is intentionally NOT
     *      bypassed -- it does not call this path. An unauthorized caller could
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

        DynamicERC4626CollateralData storage data = _getStorage();
        require(data.shares >= shares, "Insufficient shares");

        uint256 remainingShares = data.shares - shares;
        uint256 remainingValue = _resolveCollateralValue(vault, remainingShares);
        require(remainingValue >= data.depositedAssetValue, "Would remove principal");

        data.shares = remainingShares;

        // Solvency revert uses raw debt: pending reward credits may unwind.
        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault);
        require(getTotalDebt(portfolioFactoryConfig) <= newMaxLoanIgnoreSupply, "Debt exceeds max loan");
    }
}
