// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IYieldBasisGauge} from "../../../interfaces/IYieldBasisGauge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {YieldBasisCollateralManager} from "./YieldBasisCollateralManager.sol";
import {ICollateralFacet} from "../collateral/ICollateralFacet.sol";

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
contract YieldBasisLpFacet is AccessControl, ICollateralFacet {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    IYieldBasisGauge public immutable _gauge;
    IERC20 public immutable _lpToken;
    address public immutable _rewardToken;
    address public immutable _underlying;

    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event Unstaked(uint256 assets, uint256 sharesBurned, uint256 rewardsClaimed);
    event Staked(uint256 assets, uint256 sharesMinted);

    constructor(address portfolioFactory, address gauge, address rewardToken, address underlying) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(gauge != address(0), "Invalid gauge");
        require(rewardToken != address(0), "Invalid reward token");
        require(underlying != address(0), "Invalid underlying");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _gauge = IYieldBasisGauge(gauge);
        _lpToken = IERC20(IYieldBasisGauge(gauge).asset());
        _rewardToken = rewardToken;
        _underlying = underlying;
    }

    function _config() internal view returns (address) {
        return address(_portfolioFactory.portfolioFactoryConfig());
    }

    // ============ Staked Gauge Mode ============
    function isStakedGaugeMode() public view returns (bool) {
        return _gauge.balanceOf(address(this)) > 0;
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
        if(isStakedGaugeMode()) {
            _stake(amount);
        }
    }

    /**
     * @notice Withdraw LP token: remove collateral, unstake from gauge, send to owner
     * @param amount Amount of LP token to withdraw
     */
    function withdraw(uint256 amount) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(amount > 0, "Zero amount");

        // Cap to tracked: harvestLpFees may have reduced shares via removeSharesForYield.
        uint256 trackedShares = YieldBasisCollateralManager.getCollateralShares();
        uint256 toWithdraw = amount > trackedShares ? trackedShares : amount;
        if (toWithdraw == 0) return;

        YieldBasisCollateralManager.removeCollateral(_config(), address(_lpToken), _underlying, toWithdraw);

        if (isStakedGaugeMode()) {
            _gauge.withdraw(toWithdraw, address(this), address(this));
        }

        address owner = _portfolioFactory.ownerOf(address(this));
        _lpToken.safeTransfer(owner, toWithdraw);
        emit Withdrawn(owner, toWithdraw);
    }

    // ============ Admin: Yield Mode Switch ============

    /**
     * @notice Unstake all LP from gauge to earn trading fees (forgoes YB emissions)
     * @dev Admin-only: protocol decides which yield mode is optimal.
     *      Does NOT modify collateral tracking — LP stays in portfolio account.
     *      All-or-nothing: redeems the full gauge balance.
     */
    function unstake() external onlyAuthorizedCaller(_portfolioFactory) {
        uint256 shares = _gauge.balanceOf(address(this));
        require(shares > 0, "Nothing staked");
        uint256 claimed = _gauge.claim(_rewardToken, address(this));
        uint256 assets = _gauge.redeem(shares, address(this), address(this));
        emit Unstaked(assets, shares, claimed);
    }

    /**
     * @notice Stake all unstaked LP into gauge to earn YB emissions (forgoes trading fees)
     * @dev Admin-only: protocol decides which yield mode is optimal.
     *      Does NOT modify collateral tracking — LP was already tracked from deposit.
     *      All-or-nothing: stakes the full unstaked LP balance.
     */
    function stake() external onlyAuthorizedCaller(_portfolioFactory) {
        _stake(_lpToken.balanceOf(address(this)));
    }

    function _stake(uint256 amount) internal {
        _lpToken.approve(address(_gauge), amount);
        _gauge.deposit(amount, address(this));
        _lpToken.approve(address(_gauge), 0);
        emit Staked(amount, amount);
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

    function getLTVRatio() external view override returns (uint256) {
        return YieldBasisCollateralManager.getLTVRatio(_config(), address(_lpToken), _underlying);
    }
}
