// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ILoanConfig} from "../config/ILoanConfig.sol";
import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {ILendingVault} from "../../../interfaces/ILendingVault.sol";
import {PortfolioFactoryConfig} from "../config/PortfolioFactoryConfig.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../accounts/PortfolioManager.sol";
import {IYieldBasisLP} from "../../../interfaces/IYieldBasisLP.sol";
import {IYieldBasisGauge} from "../../../interfaces/IYieldBasisGauge.sol";

/**
 * @title DynamicYieldBasisCollateralManager
 * @dev Manages YieldBasis LP tokens as collateral when the lending pool keeps
 *      per-borrower debt in its own storage and may mutate it independently of
 *      borrow/pay calls (e.g. reward streaming that auto-decrements debt).
 *
 *      Debt is never cached. Every read fetches from the pool via
 *      `getDebtBalance` (raw) or `getEffectiveDebtBalance` (raw minus pending
 *      reward credits that have not yet been settled into the stored balance).
 *
 *      Read-by-purpose split:
 *      - Solvency reverts use raw debt (getTotalDebt). Conservative -- the
 *        borrower owes that amount today, regardless of pending streams.
 *      - Headroom and utilization views use effective debt
 *        (getEffectiveTotalDebt). Surfaces the in-flight reward credit so
 *        max-loan availability reflects the pool's streaming benefit before
 *        the next settlement call.
 *
 *      Uses its own storage slot, distinct from YieldBasisCollateralManager,
 *      so the cached-debt and live-read variants can be installed on
 *      different diamonds without slot collision.
 */
library DynamicYieldBasisCollateralManager {
    using SafeERC20 for IERC20;

    error InsufficientCollateral();
    error BadDebt(uint256 debt);
    error UndercollateralizedDebt(uint256 debt);
    error NotPortfolioManager();
    error InsufficientShareBalance(uint256 required, uint256 actual);
    error LtvRequiresLikeToLike();

    event YieldBasisCollateralAdded(address indexed vault, uint256 shares, uint256 assetValue, address indexed owner);
    event YieldBasisCollateralRemoved(address indexed vault, uint256 shares, uint256 assetValue, address indexed owner);

    struct DynamicYieldBasisCollateralData {
        uint256 shares;
        uint256 depositedAssetValue;
        uint256 overSuppliedVaultDebt;
        uint256 startShortfall;
        uint256 snapshotBlockNumber;
        address gauge;
    }

    error GaugeMismatch(address stored, address provided);
    error BelowMinimumCollateral(uint256 remaining, uint256 minimum);

    bytes32 private constant STORAGE_POSITION = keccak256("storage.DynamicYieldBasisCollateralManager");

    function _getStorage() internal pure returns (DynamicYieldBasisCollateralData storage data) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            data.slot := position
        }
    }

    /**
     * @dev Conservative mark for collateral checks (LTV, max-loan, liquidation).
     *      Uses min(EMA fair value, current Curve withdrawable) so a pool
     *      imbalance gap does not silently accumulate as bad debt.
     *
     *      pricePerShare() is 18-dec normalized regardless of underlying;
     *      preview_withdraw() returns underlying-native. Rescale withdrawable
     *      up to 18-dec so the min() compares like with like. Output is always
     *      18-dec -- the convention every downstream caller already expects.
     */
    ///      revertOnFail governs a reverting pricePerShare/preview_withdraw (e.g.
    ///      paused YB market): borrow-side reads pass true and re-bubble the
    ///      revert; the repay path passes false and gets ok=false so it can skip
    ///      the shortfall snapshot instead of blocking debt reduction.
    function _resolveCollateralValue(address vault, address underlying, uint256 shares, bool revertOnFail) internal view returns (uint256 value, bool ok) {
        if (shares == 0 || vault == address(0)) return (0, true);
        uint256 fundamental;
        uint256 withdrawable;
        try IYieldBasisLP(vault).pricePerShare() returns (uint256 pps) {
            fundamental = (shares * pps) / 1e18;
        } catch (bytes memory reason) {
            if (revertOnFail) {
                assembly { revert(add(reason, 0x20), mload(reason)) }
            }
            return (0, false);
        }
        try IYieldBasisLP(vault).preview_withdraw(shares) returns (uint256 w) {
            withdrawable = w;
        } catch (bytes memory reason) {
            if (revertOnFail) {
                assembly { revert(add(reason, 0x20), mload(reason)) }
            }
            return (0, false);
        }
        if (underlying != address(0)) {
            uint8 dec = IERC20Metadata(underlying).decimals();
            if (dec < 18) {
                withdrawable = withdrawable * (10 ** (18 - dec));
            } else if (dec > 18) {
                withdrawable = withdrawable / (10 ** (dec - 18));
            }
        }
        return (fundamental < withdrawable ? fundamental : withdrawable, true);
    }

    /**
     * @dev Basis-side valuation (pps only, no TRD discount). Used to stamp
     *      depositedAssetValue and to compute harvest surplus, so pool
     *      imbalance never blocks lender-premium flow when real pps growth has
     *      occurred. Honest delivery on the Curve burn is enforced separately
     *      by the slippage floor in the claiming facet.
     */
    function _resolveBasisValue(address vault, uint256 shares) internal view returns (uint256) {
        if (shares == 0 || vault == address(0)) return 0;
        return (shares * IYieldBasisLP(vault).pricePerShare()) / 1e18;
    }

    /// @dev Recoverable LP on the account: direct LP balance plus gauge receipt
    ///      shares converted to LP via `convertToAssets`. Shared between the
    ///      mutating ratchet in `_snapshotIfNeeded` and the in-memory clamp in
    ///      `getTotalCollateralValue` so the two paths cannot drift.
    ///      revertOnFail governs a reverting gauge convertToAssets (e.g. paused
    ///      gauge): borrow-side reads pass true and re-bubble the revert; the
    ///      repay path passes false and gets ok=false so it can skip the ratchet
    ///      and snapshot instead of blocking debt reduction.
    function _actualLp(address vault, address gauge, bool revertOnFail) internal view returns (uint256 lp, bool ok) {
        lp = IERC20(vault).balanceOf(address(this));
        if (gauge != address(0)) {
            uint256 gaugeShares = IERC20(gauge).balanceOf(address(this));
            if (gaugeShares > 0) {
                try IYieldBasisGauge(gauge).convertToAssets(gaugeShares) returns (uint256 assets) {
                    lp += assets;
                } catch (bytes memory reason) {
                    if (revertOnFail) {
                        assembly { revert(add(reason, 0x20), mload(reason)) }
                    }
                    return (0, false);
                }
            }
        }
        ok = true;
    }

    function addCollateral(address portfolioFactoryConfig, address vault, address gauge, address underlying, uint256 shares) public {
        require(vault != address(0), "Invalid vault address");
        require(shares > 0, "Shares must be > 0");
        DynamicYieldBasisCollateralData storage data = _getStorage();
        if (data.gauge == address(0)) {
            data.gauge = gauge;
        } else if (gauge != address(0) && data.gauge != gauge) {
            revert GaugeMismatch(data.gauge, gauge);
        }

        // Pass `shares` as incoming so the snapshot sees pre-deposit LP.
        _snapshotIfNeeded(portfolioFactoryConfig, vault, underlying, shares);

        uint256 requiredBalance = data.shares + shares;
        (uint256 actualBalance, ) = _actualLp(vault, gauge, true);
        if (actualBalance < requiredBalance) {
            revert InsufficientShareBalance(requiredBalance, actualBalance);
        }

        uint256 assetValue = _resolveBasisValue(vault, shares);

        uint256 prevShares = data.shares;
        data.shares += shares;
        data.depositedAssetValue += assetValue;

        emit YieldBasisCollateralAdded(vault, shares, assetValue, address(this));

        if (prevShares == 0) {
            _notifyCollateralAdded(portfolioFactoryConfig, vault);
        }
    }

    function removeCollateral(address portfolioFactoryConfig, address vault, address underlying, uint256 shares) public {
        require(shares > 0, "Shares must be > 0");
        _snapshotIfNeeded(portfolioFactoryConfig, vault, underlying);

        DynamicYieldBasisCollateralData storage data = _getStorage();
        require(data.shares >= shares, "Insufficient collateral shares");

        uint256 assetValueToRemove = (data.depositedAssetValue * shares) / data.shares;

        data.shares -= shares;
        data.depositedAssetValue -= assetValueToRemove;

        // Solvency revert uses raw debt: a borrower's pending reward credit may
        // unwind if the stream is interrupted, so collateral release is gated
        // by the actually-owed balance, not the optimistic effective view.
        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault, underlying);
        require(getTotalDebt(portfolioFactoryConfig) <= newMaxLoanIgnoreSupply, "Debt exceeds max loan");

        // Disallow leaving a dust position below the configured minimum; a full exit is allowed.
        // Remaining reads recoverable LP value, so an externally drained position reads 0 and exits cleanly.
        uint256 remaining = getTotalCollateralValue(vault, underlying);
        uint256 minimum = PortfolioFactoryConfig(portfolioFactoryConfig).getMinimumCollateral();
        if (remaining != 0 && remaining < minimum) revert BelowMinimumCollateral(remaining, minimum);

        emit YieldBasisCollateralRemoved(vault, shares, assetValueToRemove, address(this));

        if (data.shares == 0) {
            _notifyCollateralRemoved(portfolioFactoryConfig, vault);
        }
    }

    /// @dev Clamps tracked shares to actual recoverable LP before pricing so
    ///      callers never see a value backed by phantom shares. Mutation of the
    ///      stored counter happens in `_snapshotIfNeeded` on state-changing paths.
    function getTotalCollateralValue(address vault, address underlying) public view returns (uint256 totalValue) {
        DynamicYieldBasisCollateralData storage data = _getStorage();
        uint256 shares = data.shares;
        if (shares > 0 && data.gauge != address(0)) {
            (uint256 actual, ) = _actualLp(vault, data.gauge, true);
            if (shares > actual) shares = actual;
        }
        (totalValue, ) = _resolveCollateralValue(vault, underlying, shares, true);
    }

    /// @dev Borrow/health basis: appreciation above cost basis is reserved for
    ///      yield, so cap at min(depositedAssetValue, current). Falls to current
    ///      on depreciation so health still reacts to losses. Both sides 18-dec.
    function getBorrowableCollateralValue(address vault, address underlying) internal view returns (uint256) {
        uint256 current = getTotalCollateralValue(vault, underlying);
        uint256 basis = _getStorage().depositedAssetValue;
        return current < basis ? current : basis;
    }

    function getCollateral(address vault, address underlying) public view returns (
        uint256 shares,
        uint256 depositedAssetValue,
        uint256 currentAssetValue
    ) {
        DynamicYieldBasisCollateralData storage data = _getStorage();
        shares = data.shares;
        depositedAssetValue = data.depositedAssetValue;
        currentAssetValue = getTotalCollateralValue(vault, underlying);
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

    function increaseTotalDebt(
        address portfolioFactoryConfig,
        address vault,
        address underlying,
        uint256 amount
    ) public returns (uint256 loanAmount, uint256 originationFee) {
        _snapshotIfNeeded(portfolioFactoryConfig, vault, underlying);
        DynamicYieldBasisCollateralData storage data = _getStorage();

        address factory = PortfolioFactoryConfig(portfolioFactoryConfig).getPortfolioFactory();
        PortfolioManager manager = PortfolioFactory(factory).portfolioManager();
        bool isAuthorizedCaller = manager.isAuthorizedCaller(msg.sender);
        if (msg.sender != address(manager) && !isAuthorizedCaller) revert NotPortfolioManager();

        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());

        // Pre-borrow supply-side check
        (uint256 maxLoan,) = getMaxLoan(portfolioFactoryConfig, vault, underlying);
        if (amount > maxLoan) {
            data.overSuppliedVaultDebt += amount - maxLoan;
        }

        originationFee = lendingPool.borrowFromPortfolio(amount);
        loanAmount = amount - originationFee;

        // Authorized callers bypass PortfolioManager wrapper, so enforce inline
        if (isAuthorizedCaller) {
            enforceCollateralRequirements(portfolioFactoryConfig, vault, underlying);
        }

        return (loanAmount, originationFee);
    }

    function decreaseTotalDebt(
        address portfolioFactoryConfig,
        address vault,
        address underlying,
        uint256 amount
    ) public returns (uint256 excess) {
        _snapshotIfNeededRepay(portfolioFactoryConfig, vault, underlying);
        DynamicYieldBasisCollateralData storage data = _getStorage();

        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());

        // Read raw debt live, then size the payment to it. The pool may decrement
        // debt during payFromPortfolio via its internal vesting/settlement, so
        // we must clamp to the pre-call value to avoid over-paying past the
        // outstanding balance.
        uint256 totalDebt = lendingPool.getDebtBalance(address(this));
        uint256 balancePayment = totalDebt > amount ? amount : totalDebt;

        IERC20(lendingPool.lendingAsset()).approve(address(lendingPool), balancePayment);
        uint256 actualPaid = lendingPool.payFromPortfolio(balancePayment, 0);
        IERC20(lendingPool.lendingAsset()).approve(address(lendingPool), 0);

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

    /// @dev maxLoanIgnoreSupply from a collateral value. Single source of truth
    ///      shared by getMaxLoan and the repay-path shortfall computation. Reads
    ///      lending-asset config only, never the collateral source.
    function _maxLoanIgnoreSupply(
        address portfolioFactoryConfig,
        address underlying,
        uint256 totalCollateralValue
    ) internal view returns (uint256 maxLoanIgnoreSupply) {
        ILoanConfig loanConfig = PortfolioFactoryConfig(portfolioFactoryConfig).getLoanConfig();
        uint256 ltv = loanConfig.getLtv();

        if (ltv == 0) {
            // Cash-flow path: operator calibrates rewardsRate*multiplier to bake in
            // both the periodic rate and the cross-asset price; the 1e12 divisor
            // absorbs the 18-dec collateral scaling for non-18-dec lending assets.
            uint256 rewardsRate = loanConfig.getRewardsRate();
            uint256 multiplier = loanConfig.getMultiplier();
            maxLoanIgnoreSupply = (((totalCollateralValue * rewardsRate) / 1000000) *
                multiplier) / 1e12;
        } else {
            // Like-to-like path: pricePerShare returns value in LP underlying at 18-dec
            // regardless of native decimals. Downstream comparisons in _calculateMaxLoan
            // are in lending-asset native decimals, so we (a) enforce that lending asset
            // matches the LP underlying and (b) rescale to lending-asset decimals before
            // applying the LTV bps. Rescale floors -- favors protocol.
            ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());
            address lendingAsset = lendingPool.lendingAsset();
            if (lendingAsset != underlying) revert LtvRequiresLikeToLike();
            uint8 ld = IERC20Metadata(lendingAsset).decimals();
            uint256 valueNative = ld == 18
                ? totalCollateralValue
                : (ld < 18
                    ? totalCollateralValue / (10 ** (18 - ld))
                    : totalCollateralValue * (10 ** (ld - 18)));
            maxLoanIgnoreSupply = (valueNative * ltv) / 10000;
        }
    }

    function getMaxLoan(
        address portfolioFactoryConfig,
        address vault,
        address underlying
    ) public view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        uint256 totalCollateralValue = getBorrowableCollateralValue(vault, underlying);
        ILoanConfig loanConfig = PortfolioFactoryConfig(portfolioFactoryConfig).getLoanConfig();
        ILendingPool lendingPool = ILendingPool(PortfolioFactoryConfig(portfolioFactoryConfig).getLoanContract());

        maxLoanIgnoreSupply = _maxLoanIgnoreSupply(portfolioFactoryConfig, underlying, totalCollateralValue);

        uint256 outstandingCapital = lendingPool.activeAssets();

        // Supply source: vault.totalAssets() (already accounts for vesting/escrowed liabilities).
        // Cap source: LoanConfig.getMaxUtilizationBps() (single home for the cap; vault no
        // longer enforces, only the manager-side overSuppliedVaultDebt flag does).
        uint256 vaultTotalAssets = ILendingVault(lendingPool.lendingVault()).totalAssets();
        uint256 maxUtilizationBps = loanConfig.getMaxUtilizationBps();

        // Headroom uses effective debt: surfaces in-flight reward credit to the
        // borrower so available capacity reflects the stream before the next
        // settlement call.
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
    ///      100_00 = at LTV limit, >100_00 = underwater. UX value, not a
    ///      solvency gate -- enforceCollateralRequirements uses raw debt.
    function getLoanUtilization(address portfolioFactoryConfig, address vault, address underlying) public view returns (uint256) {
        uint256 totalDebt = getEffectiveTotalDebt(portfolioFactoryConfig);
        if (totalDebt == 0) return 0;

        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault, underlying);
        if (maxLoanIgnoreSupply == 0) return type(uint256).max;

        return (totalDebt * 100_00) / maxLoanIgnoreSupply;
    }

    function _currentShortfall(
        address portfolioFactoryConfig,
        address vault,
        address underlying
    ) internal view returns (uint256) {
        (, uint256 maxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault, underlying);
        // Solvency shortfall uses raw debt. Pending reward credits do not
        // discount the borrower's actual owed balance until settled.
        uint256 debt = getTotalDebt(portfolioFactoryConfig);
        return debt > maxLoanIgnoreSupply ? debt - maxLoanIgnoreSupply : 0;
    }

    function snapshotShortfall(address portfolioFactoryConfig, address vault, address underlying) public {
        _snapshotIfNeeded(portfolioFactoryConfig, vault, underlying);
    }

    /// @dev Populates `data.gauge` (if unset) and shrinks `data.shares` plus
    ///      `data.depositedAssetValue` to actual recoverable LP. One-way ratchet:
    ///      never grows. Called both from admin paths directly and from
    ///      `_snapshotIfNeeded` on the first state-changing touch of each block.
    function reconcileSharesToBalance(
        address portfolioFactoryConfig,
        address vault,
        address /* underlying */,
        address gauge
    ) public {
        DynamicYieldBasisCollateralData storage data = _getStorage();
        if (data.gauge == address(0)) {
            data.gauge = gauge;
        } else if (gauge != address(0) && data.gauge != gauge) {
            revert GaugeMismatch(data.gauge, gauge);
        }
        if (data.shares == 0 || data.gauge == address(0)) return;
        (uint256 actual, ) = _actualLp(vault, data.gauge, true);
        if (data.shares <= actual) return;
        data.depositedAssetValue = (data.depositedAssetValue * actual) / data.shares;
        data.shares = actual;
        if (actual == 0) {
            _notifyCollateralRemoved(portfolioFactoryConfig, vault);
        }
    }

    function enforceCollateralRequirements(
        address portfolioFactoryConfig,
        address vault,
        address underlying
    ) public view returns (bool) {
        DynamicYieldBasisCollateralData storage data = _getStorage();

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

    /// @dev Invariant entry point: every state-changing manager call goes through here.
    ///      Once per block, ratchet tracked shares down to actual recoverable LP
    ///      before computing the shortfall baseline. Ratchet is one-way and intentional:
    ///      a transient gauge drift permanently shrinks the user's tracked collateral
    ///      rather than risking borrow against phantom shares between drift and the next
    ///      admin reconcile. Surplus from later gauge appreciation must be added back
    ///      via explicit addCollateral.
    function _snapshotIfNeeded(address portfolioFactoryConfig, address vault, address underlying) internal {
        _snapshotIfNeeded(portfolioFactoryConfig, vault, underlying, 0);
    }

    /// @dev Drift-aware variant: subtracts `incomingShares` from `_actualLp`
    ///      so a deposit-in-flight cannot mask drift. Inlined (not delegated
    ///      to the public `reconcileSharesToBalance`) so the untrusted offset
    ///      stays internal-only.
    function _snapshotIfNeeded(
        address portfolioFactoryConfig,
        address vault,
        address underlying,
        uint256 incomingShares
    ) internal {
        DynamicYieldBasisCollateralData storage data = _getStorage();
        if (data.snapshotBlockNumber == block.number) return;
        data.snapshotBlockNumber = block.number;

        if (data.shares > 0) {
            (uint256 actual, ) = _actualLp(vault, data.gauge, true);
            uint256 effective = actual > incomingShares ? actual - incomingShares : 0;
            if (data.shares > effective) {
                data.depositedAssetValue = (data.depositedAssetValue * effective) / data.shares;
                data.shares = effective;
                if (effective == 0) {
                    _notifyCollateralRemoved(portfolioFactoryConfig, vault);
                }
            }
        }

        data.startShortfall = _currentShortfall(portfolioFactoryConfig, vault, underlying);
    }

    /// @dev Repay-path snapshot. Ratchets shares and records the shortfall baseline
    ///      only if the collateral reads succeed; a paused gauge (ratchet read) or
    ///      paused YB market (shortfall read) skips the snapshot instead of blocking
    ///      the repay. Debt is read live, so no sync is needed. A later borrow-side op
    ///      in the same block re-attempts the strict reads and still reverts. The
    ///      snapshot block is marked only after both reads succeed. Shortfall uses raw
    ///      debt, matching _currentShortfall.
    function _snapshotIfNeededRepay(address portfolioFactoryConfig, address vault, address underlying) internal {
        DynamicYieldBasisCollateralData storage data = _getStorage();
        if (data.snapshotBlockNumber == block.number) return;

        if (data.shares > 0) {
            (uint256 actual, bool lpOk) = _actualLp(vault, data.gauge, false);
            if (!lpOk) return;
            if (data.shares > actual) {
                data.depositedAssetValue = (data.depositedAssetValue * actual) / data.shares;
                data.shares = actual;
                if (actual == 0) {
                    _notifyCollateralRemoved(portfolioFactoryConfig, vault);
                }
            }
        }

        (uint256 collateralValue, bool valOk) = _resolveCollateralValue(vault, underlying, data.shares, false);
        if (!valOk) return;
        // Mirror getBorrowableCollateralValue: cap at cost basis so the repay
        // baseline matches the borrow-side shortfall computation.
        uint256 basis = data.depositedAssetValue;
        uint256 borrowable = collateralValue < basis ? collateralValue : basis;
        uint256 maxLoanIgnoreSupply = _maxLoanIgnoreSupply(portfolioFactoryConfig, underlying, borrowable);
        uint256 debt = getTotalDebt(portfolioFactoryConfig);
        data.snapshotBlockNumber = block.number;
        data.startShortfall = debt > maxLoanIgnoreSupply ? debt - maxLoanIgnoreSupply : 0;
    }

    /**
     * @dev Reduce tracked LP shares to reflect harvested yield, holding
     *      depositedAssetValue fixed. Accounting only; the paired LP burn lives in
     *      the claiming facet. Three checks bound any caller: remaining basis must
     *      still cover depositedAssetValue (no principal removal), the fixed basis
     *      blocks re-harvesting principal as fake yield at flat pps, and debt must
     *      stay within max-loan. isAuthorizedCaller-gated; a standalone call can
     *      only desync tracking downward (recoverable via addCollateral), never up.
     */
    function removeSharesForYield(
        address portfolioFactoryConfig,
        address vault,
        address underlying,
        uint256 shares
    ) public {
        _snapshotIfNeeded(portfolioFactoryConfig, vault, underlying);
        DynamicYieldBasisCollateralData storage data = _getStorage();

        address factory = PortfolioFactoryConfig(portfolioFactoryConfig).getPortfolioFactory();
        require(
            PortfolioFactory(factory).portfolioManager().isAuthorizedCaller(msg.sender),
            "Unauthorized"
        );

        require(data.shares >= shares, "Insufficient shares");

        uint256 remainingShares = data.shares - shares;
        uint256 remainingValue = _resolveBasisValue(vault, remainingShares);
        require(remainingValue >= data.depositedAssetValue, "Would remove principal");

        data.shares = remainingShares;

        // Solvency revert uses raw debt: pending reward credits may unwind.
        (, uint256 newMaxLoanIgnoreSupply) = getMaxLoan(portfolioFactoryConfig, vault, underlying);
        require(getTotalDebt(portfolioFactoryConfig) <= newMaxLoanIgnoreSupply, "Debt exceeds max loan");

        if (data.shares == 0) {
            _notifyCollateralRemoved(portfolioFactoryConfig, vault);
        }
    }

    function _notifyCollateralAdded(address portfolioFactoryConfig, address lp) internal {
        try PortfolioFactoryConfig(portfolioFactoryConfig).onCollateralAdded(lp, 0) {} catch {}
    }

    function _notifyCollateralRemoved(address portfolioFactoryConfig, address lp) internal {
        try PortfolioFactoryConfig(portfolioFactoryConfig).onCollateralRemoved(lp, 0) {} catch {}
    }
}
