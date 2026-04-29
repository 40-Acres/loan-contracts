// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ILoanConfig} from "../config/ILoanConfig.sol";
import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {PortfolioFactoryConfig} from "../config/PortfolioFactoryConfig.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../accounts/PortfolioManager.sol";
import {IYieldBasisLP} from "../../../interfaces/IYieldBasisLP.sol";

interface IYieldBasisDebtBalanceReader {
    function getDebtBalance(address borrower) external view returns (uint256);
}

/**
 * @title YieldBasisCollateralManager
 * @dev Library for managing YieldBasis LP tokens as collateral.
 *
 * The YB LP token (e.g. yb-WETH at 0x931d40dD07b25B91932b481B63631Ea86d236e09) is NOT
 * ERC4626 — it has no convertToAssets/convertToShares/asset(). It exposes pricePerShare()
 * only. Trying to price it through ERC4626CollateralManager's convertToAssets call path
 * reverts with empty returndata.
 *
 * This manager treats the LP token directly as the collateral primitive:
 *   - `vault` param on every external method = the YB LP token
 *   - `underlying` param = the asset the LP represents (e.g. WETH), carried through for
 *     semantic clarity; pricing does not depend on it.
 *   - shares stored in `data.shares` are LP token amounts
 *   - collateral value = shares * IYieldBasisLP(vault).pricePerShare() / 1e18
 *
 * Gauge interactions (stake/unstake) live in YieldBasisLpFacet.stake/unstake. The gauge
 * address is passed into addCollateral so the balance check can count gauge shares (a
 * separate ERC20 representing staked LP 1:1) toward the required balance — without it,
 * deposits while in staked mode would revert because prior LP has left the account.
 *
 * Uses its own ERC-7201 storage slot, distinct from ERC4626CollateralManager, so this
 * manager and the ERC4626 one can be installed side-by-side on different diamonds.
 */
library YieldBasisCollateralManager {
    using SafeERC20 for IERC20;

    error InsufficientCollateral();
    error BadDebt(uint256 debt);
    error UndercollateralizedDebt(uint256 debt);
    error NotPortfolioManager();
    error InsufficientShareBalance(uint256 required, uint256 actual);

    event YieldBasisCollateralAdded(address indexed vault, uint256 shares, uint256 assetValue, address indexed owner);
    event YieldBasisCollateralRemoved(address indexed vault, uint256 shares, uint256 assetValue, address indexed owner);

    struct YieldBasisCollateralData {
        uint256 shares;
        uint256 depositedAssetValue;
        uint256 debt;
        uint256 overSuppliedVaultDebt;
        uint256 startShortfall;
        uint256 snapshotBlockNumber;
    }

    bytes32 private constant STORAGE_POSITION = keccak256("storage.YieldBasisCollateralManager");

    function _getStorage() internal pure returns (YieldBasisCollateralData storage data) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            data.slot := position
        }
    }

    /**
     * @dev shares × vault.pricePerShare() / 1e18. `underlying` is unused in the math —
     * it is the denomination the returned value is conceptually in (e.g. WETH for yb-WETH)
     * and is kept on the signature for call-site clarity.
     */
    function _resolveCollateralValue(address vault, address /*underlying*/, uint256 shares) internal view returns (uint256 value) {
        if (shares == 0 || vault == address(0)) return 0;
        uint256 pps = IYieldBasisLP(vault).pricePerShare();
        return (shares * pps) / 1e18;
    }

    function addCollateral(address portfolioFactoryConfig, address vault, address gauge, address underlying, uint256 shares) public {
        require(vault != address(0), "Invalid vault address");
        require(shares > 0, "Shares must be > 0");
        _snapshotIfNeeded(portfolioFactoryConfig, vault, underlying);
        YieldBasisCollateralData storage data = _getStorage();

        // Staked LP lives in the gauge as a separate ERC20 (1:1 with LP). Count both
        // unstaked LP on the account and gauge shares as collateral-bearing balance.
        uint256 requiredBalance = data.shares + shares;
        uint256 actualBalance = IERC20(vault).balanceOf(address(this));
        if (gauge != address(0)) {
            actualBalance += IERC20(gauge).balanceOf(address(this));
        }
        if (actualBalance < requiredBalance) {
            revert InsufficientShareBalance(requiredBalance, actualBalance);
        }

        uint256 assetValue = _resolveCollateralValue(vault, underlying, shares);

        data.shares += shares;
        data.depositedAssetValue += assetValue;

        emit YieldBasisCollateralAdded(vault, shares, assetValue, address(this));
    }

    function removeCollateral(address portfolioFactoryConfig, address vault, address underlying, uint256 shares) public {
        require(shares > 0, "Shares must be > 0");
        _snapshotIfNeeded(portfolioFactoryConfig, vault, underlying);

        YieldBasisCollateralData storage data = _getStorage();
        require(data.shares >= shares, "Insufficient collateral shares");

        uint256 assetValueToRemove = (data.depositedAssetValue * shares) / data.shares;

        data.shares -= shares;
        data.depositedAssetValue -= assetValueToRemove;

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault, underlying);
        require(getTotalDebt() <= newMaxLoanIgnoreSupply, "Debt exceeds max loan");

        emit YieldBasisCollateralRemoved(vault, shares, assetValueToRemove, address(this));
    }

    function getTotalCollateralValue(address vault, address underlying) public view returns (uint256 totalValue) {
        YieldBasisCollateralData storage data = _getStorage();
        totalValue = _resolveCollateralValue(vault, underlying, data.shares);
    }

    function getCollateral(address vault, address underlying) public view returns (
        uint256 shares,
        uint256 depositedAssetValue,
        uint256 currentAssetValue
    ) {
        YieldBasisCollateralData storage data = _getStorage();
        shares = data.shares;
        depositedAssetValue = data.depositedAssetValue;
        currentAssetValue = _resolveCollateralValue(vault, underlying, shares);
    }

    function getCollateralShares() external view returns (uint256) {
        return _getStorage().shares;
    }

    function getTotalDebt() public view returns (uint256) {
        return _getStorage().debt;
    }

    function increaseTotalDebt(
        address portfolioFactoryConfig,
        address vault,
        address underlying,
        uint256 amount
    ) public returns (uint256 loanAmount, uint256 originationFee) {
        _snapshotIfNeeded(portfolioFactoryConfig, vault, underlying);
        YieldBasisCollateralData storage data = _getStorage();

        address factory = PortfolioFactoryConfig(portfolioFactoryConfig).getPortfolioFactory();
        PortfolioManager manager = PortfolioFactory(factory).portfolioManager();
        if (msg.sender != address(manager) && !manager.isAuthorizedCaller(msg.sender)) revert NotPortfolioManager();

        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());

        (uint256 maxLoan,) = getMaxLoan(portfolioFactoryConfig, vault, underlying);

        if (amount > maxLoan) {
            data.overSuppliedVaultDebt += amount - maxLoan;
        }

        originationFee = lendingPool.borrowFromPortfolio(amount);
        loanAmount = amount - originationFee;

        data.debt = IYieldBasisDebtBalanceReader(address(lendingPool)).getDebtBalance(address(this));

        return (loanAmount, originationFee);
    }

    function decreaseTotalDebt(
        address portfolioFactoryConfig,
        address vault,
        address underlying,
        uint256 amount
    ) public returns (uint256 excess) {
        _snapshotIfNeeded(portfolioFactoryConfig, vault, underlying);
        YieldBasisCollateralData storage data = _getStorage();

        uint256 totalDebt = data.debt;
        uint256 balancePayment = totalDebt > amount ? amount : totalDebt;

        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());

        IERC20(lendingPool.lendingAsset()).approve(address(lendingPool), balancePayment);
        uint256 actualPaid = lendingPool.payFromPortfolio(balancePayment, 0);
        IERC20(lendingPool.lendingAsset()).approve(address(lendingPool), 0);

        excess = amount - actualPaid;

        data.debt = IYieldBasisDebtBalanceReader(address(lendingPool)).getDebtBalance(address(this));

        if (data.overSuppliedVaultDebt > 0) {
            data.overSuppliedVaultDebt -= data.overSuppliedVaultDebt > actualPaid ? actualPaid : data.overSuppliedVaultDebt;
        }

        return excess;
    }

    function getMaxLoan(
        address portfolioFactoryConfig,
        address vault,
        address underlying
    ) public view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        uint256 totalCollateralValue = getTotalCollateralValue(vault, underlying);
        ILoanConfig loanConfig = PortfolioFactoryConfig(portfolioFactoryConfig).getLoanConfig();

        uint256 ltv = loanConfig.getMultiplier();
        maxLoanIgnoreSupply = (totalCollateralValue * ltv) / 10000;

        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());
        uint256 outstandingCapital = lendingPool.activeAssets();

        address lendingVault = lendingPool.lendingVault();
        address lendingUnderlying = IERC4626(lendingVault).asset();
        uint256 vaultBalance = IERC20(lendingUnderlying).balanceOf(lendingVault);

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

    function getLTVRatio(address portfolioFactoryConfig, address vault, address underlying) public view returns (uint256) {
        uint256 totalDebt = getTotalDebt();
        if (totalDebt == 0) return 0;

        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault, underlying);
        if (maxLoanIgnoreSupply == 0) return type(uint256).max;

        return (totalDebt * 100) / maxLoanIgnoreSupply;
    }

    function _currentShortfall(
        address portfolioFactoryConfig,
        address vault,
        address underlying
    ) internal view returns (uint256) {
        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault, underlying);
        uint256 debt = getTotalDebt();
        return debt > maxLoanIgnoreSupply ? debt - maxLoanIgnoreSupply : 0;
    }

    function snapshotShortfall(address portfolioFactoryConfig, address vault, address underlying) public {
        _snapshotIfNeeded(portfolioFactoryConfig, vault, underlying);
    }

    function enforceCollateralRequirements(
        address portfolioFactoryConfig,
        address vault,
        address underlying
    ) public view returns (bool) {
        YieldBasisCollateralData storage data = _getStorage();

        uint256 end = _currentShortfall(portfolioFactoryConfig, vault, underlying);
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
        _getStorage().debt = IYieldBasisDebtBalanceReader(address(lendingPool)).getDebtBalance(address(this));
    }

    function _snapshotIfNeeded(address portfolioFactoryConfig, address vault, address underlying) internal {
        _syncDebt(portfolioFactoryConfig);
        YieldBasisCollateralData storage data = _getStorage();
        if (data.snapshotBlockNumber != block.number) {
            data.snapshotBlockNumber = block.number;
            data.startShortfall = _currentShortfall(portfolioFactoryConfig, vault, underlying);
        }
    }

    function removeSharesForYield(
        address portfolioFactoryConfig,
        address vault,
        address underlying,
        uint256 shares
    ) public {
        _snapshotIfNeeded(portfolioFactoryConfig, vault, underlying);
        YieldBasisCollateralData storage data = _getStorage();
        require(data.shares >= shares, "Insufficient shares");

        uint256 remainingShares = data.shares - shares;
        uint256 remainingValue = _resolveCollateralValue(vault, underlying, remainingShares);
        require(remainingValue >= data.depositedAssetValue, "Would remove principal");

        data.shares = remainingShares;

        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault, underlying);
        require(getTotalDebt() <= newMaxLoanIgnoreSupply, "Debt exceeds max loan");
    }
}
