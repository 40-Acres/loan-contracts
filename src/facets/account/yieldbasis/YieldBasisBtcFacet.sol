// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IYieldBasisGauge} from "../../../interfaces/IYieldBasisGauge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";

/**
 * @title YieldBasisBtcFacet
 * @dev Manages staking/unstaking of ybBTC in YieldBasis gauges.
 *
 * When ybBTC is staked in a gauge, it earns YB emissions (Token Yield).
 * When unstaked, ybBTC earns trading fees via price-per-share appreciation (Trading Yield).
 *
 * Unstaking does NOT affect collateral tracking — gauge shares and ybBTC are 1:1,
 * so the collateral value is preserved regardless of staking state.
 */
contract YieldBasisBtcFacet is AccessControl {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    IYieldBasisGauge public immutable _gauge;
    IERC20 public immutable _ybBtc;

    event Unstaked(uint256 assets, uint256 sharesBurned);
    event Restaked(uint256 assets, uint256 sharesMinted);

    constructor(address portfolioFactory, address gauge) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(gauge != address(0), "Invalid gauge");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _gauge = IYieldBasisGauge(gauge);
        _ybBtc = IERC20(IYieldBasisGauge(gauge).asset());
    }

    /**
     * @notice Unstake ybBTC from the gauge to earn trading fees instead of YB emissions
     * @param amount Amount of ybBTC to unstake
     */
    function unstake(uint256 amount) external onlyAuthorizedCaller(_portfolioFactory) {
        require(amount > 0, "Zero amount");
        uint256 sharesBurned = _gauge.withdraw(amount, address(this), address(this));
        emit Unstaked(amount, sharesBurned);
    }

    /**
     * @notice Restake ybBTC into the gauge to earn YB emissions
     * @param amount Amount of ybBTC to stake
     */
    function restake(uint256 amount) external onlyAuthorizedCaller(_portfolioFactory) {
        require(amount > 0, "Zero amount");
        _ybBtc.approve(address(_gauge), amount);
        uint256 sharesMinted = _gauge.deposit(amount, address(this));
        _ybBtc.approve(address(_gauge), 0);
        emit Restaked(amount, sharesMinted);
    }

    /**
     * @notice Get the current staking state
     * @return staked Amount of ybBTC staked in gauge (as gauge shares)
     * @return unstaked Amount of ybBTC held on this contract (not staked)
     */
    function getStakingState() external view returns (uint256 staked, uint256 unstaked) {
        staked = _gauge.balanceOf(address(this));
        unstaked = _ybBtc.balanceOf(address(this));
    }
}
