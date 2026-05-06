// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IYieldBasisGauge} from "../../../interfaces/IYieldBasisGauge.sol";
import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {YieldBasisCollateralManager} from "./YieldBasisCollateralManager.sol";
import {ICollateralFacet} from "../collateral/ICollateralFacet.sol";
import {YieldBasisPortfolioFactoryConfig} from "../config/YieldBasisPortfolioFactoryConfig.sol";
import {SequencerLivenessLib} from "../../../oracle/SequencerLivenessLib.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/**
 * @title YieldBasisLpFacet
 * @dev Manages LP token deposits, withdrawals, and gauge staking/unstaking.
 * Integrates with ERC4626CollateralManager for collateral tracking. Collateral is
 * denominated in the underlying asset (e.g. WBTC, WETH) via LP pricePerShare().
 *
 * When LP token is staked in a gauge, it earns YB emissions but forgoes trading fees.
 * When unstaked, LP token earns trading fees via price-per-share appreciation (minus dynamic admin fee to veYB).
 *
 * Deposit flow: user sends LP token → held on account → LP tracked as collateral (underlying value)
 * Withdraw flow: remove collateral tracking → unstake from gauge if needed → send LP token to user
 * Mode switch (admin only): stake/unstake to toggle between trading yield and YB emissions
 */
contract YieldBasisLpFacet is AccessControl, ICollateralFacet, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    IYieldBasisGauge public immutable _gauge;
    IERC20 public immutable _lpToken;
    address public immutable _rewardToken;
    address public immutable _underlying;

    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event Unstaked(uint256 assets, uint256 sharesBurned);
    event Staked(uint256 assets, uint256 sharesMinted);

    /// @dev `_underlying` is derived from `lendingPool.lendingAsset()` so that
    ///      collateral pricing (via LP pricePerShare) and debt comparisons
    ///      (via lendingPool) share the same denomination by construction —
    ///      no operator-passed `underlying` arg can cause unit mismatch.
    constructor(address portfolioFactory, address gauge, address rewardToken, address lendingPool) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(gauge != address(0), "Invalid gauge");
        require(rewardToken != address(0), "Invalid reward token");
        require(lendingPool != address(0), "Invalid lending pool");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _gauge = IYieldBasisGauge(gauge);
        _lpToken = IERC20(IYieldBasisGauge(gauge).asset());
        _rewardToken = rewardToken;
        _underlying = ILendingPool(lendingPool).lendingAsset();
    }

    function _config() internal view returns (address) {
        return address(_portfolioFactory.portfolioFactoryConfig());
    }

    // ============ Staked Gauge Mode ============

    /**
     * @notice Returns the protocol-wide directive that auto-stakes new LP deposits into the gauge.
     * @dev Per-account gauge state may diverge from this flag until the next
     *      deposit/withdraw or an admin sweep via setStakedMode.
     */
    function getStakedMode() public view returns (bool) {
        return YieldBasisPortfolioFactoryConfig(_config()).getStakedGaugeMode();
    }

    // ============ Deposit / Withdraw ============

    /**
     * @notice Deposit LP token: hold on account and track LP as collateral (underlying value)
     * @param amount Amount of LP token to deposit
     */
    function deposit(uint256 amount) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(amount > 0, "Zero amount");
        address owner = _portfolioFactory.ownerOf(address(this));
        IERC20(address(_lpToken)).safeTransferFrom(owner, address(this), amount);

        // depositedAssetValue stored in underlying (e.g. WETH) units via LP pricePerShare()
        YieldBasisCollateralManager.addCollateral(_config(), address(_lpToken), address(_gauge), _underlying, amount);

        emit Deposited(owner, amount);
        if (getStakedMode()) {
            _stake(amount);
        }
    }

    /**
     * @notice Withdraw LP token: remove collateral, source from direct balance and gauge as needed, send to owner
     * @dev Branches on this account's actual balances, not the factory mode flag, so it
     *      tolerates mixed states from prior flag flips, partial fee harvests, and dust.
     * @param amount Amount of LP token to withdraw
     */
    function withdraw(uint256 amount) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(amount > 0, "Zero amount");
        address config = _config();
        SequencerLivenessLib.assertUp(config);

        // Cap to tracked: harvestLpFees may have reduced shares via removeSharesForYield.
        uint256 trackedShares = YieldBasisCollateralManager.getCollateralShares();
        uint256 toWithdraw = amount > trackedShares ? trackedShares : amount;
        if (toWithdraw == 0) return;

        YieldBasisCollateralManager.removeCollateral(config, address(_lpToken), _underlying, toWithdraw);

        uint256 directLp = _lpToken.balanceOf(address(this));
        if (toWithdraw > directLp) {
            uint256 shortfall = toWithdraw - directLp;
            _gauge.withdraw(shortfall, address(this), address(this));
        }

        address owner = _portfolioFactory.ownerOf(address(this));
        _lpToken.safeTransfer(owner, toWithdraw);
        emit Withdrawn(owner, toWithdraw);
    }

    // ============ Admin: Per-Account Yield Mode Sweep ============

    /**
     * @notice Reconcile this account to the protocol-wide gauge directive.
     * @dev Reads the factory-level stakedGaugeMode flag (single source of truth)
     *      and brings this account's gauge state in line. Authorized callers
     *      cannot override the directive on a per-account basis — to flip an
     *      individual account, the admin flips the factory flag, runs this
     *      on affected accounts, and (if needed) flips the flag back.
     */
    function setStakedMode() external onlyAuthorizedCaller(_portfolioFactory) nonReentrant {
        bool staked = getStakedMode();
        if (staked) {
            uint256 lpBalance = _lpToken.balanceOf(address(this));
            require(lpBalance > 0, "Nothing to stake");
            _stake(lpBalance);
        } else {
            uint256 shares = _gauge.balanceOf(address(this));
            require(shares > 0, "Nothing staked");

            uint256 lpBefore = _lpToken.balanceOf(address(this));
            _gauge.redeem(shares, address(this), address(this));
            uint256 lpReceived = _lpToken.balanceOf(address(this)) - lpBefore;

            // Trusted boundary: reconcile tracked shares down to actual LP available.
            // Absorbs ERC4626 1-wei rounding or any future YB gauge fee/rebase as
            // accounting truth instead of locking users out of subsequent withdraw.
            YieldBasisCollateralManager.reconcileSharesToBalance(
                _config(),
                address(_lpToken),
                _underlying,
                address(_gauge)
            );

            emit Unstaked(lpReceived, shares);
        }
    }

    function _stake(uint256 amount) internal {
        uint256 lpBefore = _lpToken.balanceOf(address(this));
        _lpToken.approve(address(_gauge), amount);
        uint256 sharesMinted = _gauge.deposit(amount, address(this));
        _lpToken.approve(address(_gauge), 0);
        uint256 lpSent = lpBefore - _lpToken.balanceOf(address(this));
        emit Staked(lpSent, sharesMinted);
    }

    // ============ View Functions ============

    /**
     * @notice Get the current staking state
     * @return staked Gauge shares held (may differ from LP amount if share price != 1:1)
     * @return unstaked LP token balance held directly on this contract (not staked)
     */
    function getStakingState() external view returns (uint256 staked, uint256 unstaked) {
        staked = _gauge.balanceOf(address(this));
        unstaked = _lpToken.balanceOf(address(this));
    }

    // ============ ICollateralFacet Implementation ============

    function getTotalLockedCollateral() external view override returns (uint256) {
        return YieldBasisCollateralManager.getTotalCollateralValue(address(_lpToken), _underlying);
    }

    function getTotalDebt() external view override returns (uint256) {
        return YieldBasisCollateralManager.getTotalDebt();
    }

    function getMaxLoan() external view override returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        return YieldBasisCollateralManager.getMaxLoan(_config(), address(_lpToken), _underlying);
    }

    function enforceCollateralRequirements() external view override returns (bool success) {
        return YieldBasisCollateralManager.enforceCollateralRequirements(_config(), address(_lpToken), _underlying);
    }

    function getLoanUtilization() external view override returns (uint256) {
        return YieldBasisCollateralManager.getLoanUtilization(_config(), address(_lpToken), _underlying);
    }

    function getCollateralToken() external view override returns (address) {
        return address(_lpToken);
    }
}
