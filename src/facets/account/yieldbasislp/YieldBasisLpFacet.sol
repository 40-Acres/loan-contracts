// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IYieldBasisGauge} from "../../../interfaces/IYieldBasisGauge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {ERC4626CollateralManager} from "../erc4626/ERC4626CollateralManager.sol";
import {ICollateralFacet} from "../collateral/ICollateralFacet.sol";

/**
 * @title YieldBasisLpFacet
 * @dev Manages LP token deposits, withdrawals, and staking/unstaking in YieldBasis gauges.
 * Integrates with ERC4626CollateralManager for collateral tracking. Collateral is
 * denominated in the underlying asset (e.g. WBTC, WETH) via LP pricePerShare().
 *
 * When LP token is staked in a gauge, it earns YB emissions but forgoes trading fees.
 * When unstaked, LP token earns trading fees via price-per-share appreciation (minus dynamic admin fee to veYB).
 *
 * Deposit flow: user sends LP token → staked in gauge → gauge shares tracked as collateral (underlying value)
 * Withdraw flow: remove collateral tracking → unstake from gauge → send LP token to user
 * Mode switch (admin only): unstake/restake to toggle between trading yield and YB emissions
 */
contract YieldBasisLpFacet is AccessControl, ICollateralFacet {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    IYieldBasisGauge public immutable _gauge;
    IERC20 public immutable _lpToken;
    address public immutable _rewardToken;

    event Deposited(address indexed from, uint256 amount, uint256 sharesMinted);
    event Withdrawn(address indexed to, uint256 amount);
    event Unstaked(uint256 assets, uint256 sharesBurned, uint256 rewardsClaimed);
    event Restaked(uint256 assets, uint256 sharesMinted);

    constructor(address portfolioFactory, address gauge, address rewardToken) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(gauge != address(0), "Invalid gauge");
        require(rewardToken != address(0), "Invalid reward token");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _gauge = IYieldBasisGauge(gauge);
        _lpToken = IERC20(IYieldBasisGauge(gauge).asset());
        _rewardToken = rewardToken;
    }

    function _config() internal view returns (address) {
        return address(_portfolioFactory.portfolioFactoryConfig());
    }

    // ============ Deposit / Withdraw ============

    /**
     * @notice Deposit LP token: stake in gauge and track gauge shares as collateral (underlying value)
     * @dev LP token must already be in the portfolio account (transferred via multicall)
     * @param amount Amount of LP token to deposit and stake
     */
    function deposit(uint256 amount) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(amount > 0, "Zero amount");
        _lpToken.approve(address(_gauge), amount);
        uint256 sharesMinted = _gauge.deposit(amount, address(this));
        _lpToken.approve(address(_gauge), 0);

        // Track gauge shares as collateral — depositedAssetValue stored in underlying (e.g. BTC) units
        ERC4626CollateralManager.addCollateral(_config(), address(_gauge), address(_lpToken), sharesMinted);

        emit Deposited(msg.sender, amount, sharesMinted);
    }

    /**
     * @notice Withdraw LP token: remove collateral, unstake from gauge, send to owner
     * @param amount Amount of LP token to withdraw
     */
    function withdraw(uint256 amount) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        require(amount > 0, "Zero amount");

        // Always remove collateral for the full withdrawal amount
        uint256 sharesToRemove = _gauge.previewWithdraw(amount);
        ERC4626CollateralManager.removeCollateral(_config(), address(_gauge), address(_lpToken), sharesToRemove);

        // Only unstake from gauge for the portion not already held as LP
        uint256 unstaked = _lpToken.balanceOf(address(this));
        uint256 toUnstake = unstaked < amount ? amount - unstaked : 0;
        if (toUnstake > 0) {
            _gauge.withdraw(toUnstake, address(this), address(this));
        }

        // Transfer LP tokens to owner
        address owner = _portfolioFactory.ownerOf(address(this));
        _lpToken.safeTransfer(owner, amount);
        emit Withdrawn(owner, amount);
    }

    // ============ Admin: Yield Mode Switch ============

    /**
     * @notice Unstake LP token from gauge to earn trading fees (forgoes YB emissions)
     * @dev Admin-only: protocol decides which yield mode is optimal.
     *      Does NOT modify collateral tracking — LP stays in portfolio account.
     * @param shares Amount of gauge shares to redeem
     */
    function unstake(uint256 shares) external onlyAuthorizedCaller(_portfolioFactory) {
        require(shares > 0, "Zero amount");
        uint256 claimed = _gauge.claim(_rewardToken, address(this));
        uint256 assets = _gauge.redeem(shares, address(this), address(this));
        emit Unstaked(assets, shares, claimed);
    }

    /**
     * @notice Restake LP token into gauge to earn YB emissions (forgoes trading fees)
     * @dev Admin-only: protocol decides which yield mode is optimal.
     *      Does NOT modify collateral tracking — LP was already tracked from deposit.
     * @param amount Amount of LP token to stake
     */
    function restake(uint256 amount) external onlyAuthorizedCaller(_portfolioFactory) {
        require(amount > 0, "Zero amount");
        _lpToken.approve(address(_gauge), amount);
        _gauge.deposit(amount, address(this));
        _lpToken.approve(address(_gauge), 0);
        emit Restaked(amount, amount);
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
        return ERC4626CollateralManager.getTotalCollateralValue(address(_gauge), address(_lpToken));
    }

    function getTotalDebt() external view override returns (uint256) {
        return ERC4626CollateralManager.getTotalDebt();
    }

    function getMaxLoan() external view override returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply) {
        return ERC4626CollateralManager.getMaxLoan(_config(), address(_gauge), address(_lpToken));
    }

    function enforceCollateralRequirements() external view override returns (bool success) {
        return ERC4626CollateralManager.enforceCollateralRequirements(_config(), address(_gauge), address(_lpToken));
    }

    function getLTVRatio() external view override returns (uint256) {
        return ERC4626CollateralManager.getLTVRatio(_config(), address(_gauge), address(_lpToken));
    }
}
