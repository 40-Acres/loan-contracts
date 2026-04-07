// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IYieldBasisGauge} from "../../../interfaces/IYieldBasisGauge.sol";
import {IYieldBasisLP} from "../../../interfaces/IYieldBasisLP.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {ERC4626CollateralManager} from "../erc4626/ERC4626CollateralManager.sol";

/**
 * @title YieldBasisLpFeeClaimingFacet
 * @dev Harvests LP trading fee yield from pricePerShare appreciation.
 *
 * When LP tokens are staked in a gauge, trading fees still accrue to the LP token
 * (pricePerShare increases). This facet extracts the yield by:
 * 1. Computing how much gauge share value exceeds the deposited underlying value
 * 2. Redeeming surplus gauge shares for LP tokens
 * 3. Withdrawing LP tokens from the YB pool for the underlying asset (e.g. WBTC)
 * 4. Leaving the underlying on the portfolio account for RewardsProcessingFacet
 */
contract YieldBasisLpFeeClaimingFacet is AccessControl {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    IYieldBasisGauge public immutable _gauge;
    IYieldBasisLP public immutable _lpToken;

    event LpFeesHarvested(uint256 gaugeSharesRedeemed, uint256 lpTokensBurned, uint256 underlyingReceived, address indexed owner);

    constructor(address portfolioFactory, address gauge) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(gauge != address(0), "Invalid gauge");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _gauge = IYieldBasisGauge(gauge);
        _lpToken = IYieldBasisLP(IYieldBasisGauge(gauge).asset());
    }

    /**
     * @notice Harvest LP trading fee yield (pricePerShare appreciation)
     * @dev Redeems surplus gauge shares, withdraws LP tokens for underlying asset.
     *      Underlying asset stays on the portfolio account for RewardsProcessingFacet.
     * @param minUnderlyingOut Minimum underlying asset to receive (slippage protection)
     * @return underlyingReceived Amount of underlying asset harvested
     */
    function harvestLpFees(uint256 minUnderlyingOut) external onlyAuthorizedCaller(_portfolioFactory) returns (uint256 underlyingReceived) {
        address config = address(_portfolioFactory.portfolioFactoryConfig());
        address gauge = address(_gauge);
        address lpToken = address(_lpToken);

        // Get collateral state
        (uint256 trackedShares, uint256 depositedValue, uint256 currentValue) =
            ERC4626CollateralManager.getCollateral(gauge, lpToken);

        require(trackedShares > 0, "No shares deposited");
        require(currentValue > depositedValue, "No yield to harvest");

        // Compute surplus gauge shares representing fee yield
        // yieldFraction = (currentValue - depositedValue) / currentValue
        // surplusShares = trackedShares * yieldFraction
        uint256 surplusShares = (trackedShares * (currentValue - depositedValue)) / currentValue;
        require(surplusShares > 0, "Yield too small to harvest");

        // Remove surplus shares from collateral (keeps depositedAssetValue intact)
        ERC4626CollateralManager.removeSharesForYield(config, gauge, lpToken, surplusShares);

        // Redeem gauge shares for LP tokens
        uint256 lpReceived = _gauge.redeem(surplusShares, address(this), address(this));

        // Withdraw LP tokens from YB pool for underlying asset (e.g. WBTC)
        IERC20(lpToken).approve(lpToken, lpReceived);
        underlyingReceived = _lpToken.withdraw(lpReceived, minUnderlyingOut, address(this));
        IERC20(lpToken).approve(lpToken, 0);

        // Enforce collateral requirements — prevents harvesting into undercollateralization
        ERC4626CollateralManager.enforceCollateralRequirements(config, gauge, lpToken);

        emit LpFeesHarvested(surplusShares, lpReceived, underlyingReceived, _portfolioFactory.ownerOf(address(this)));
    }

    // ============ View Functions ============

    /**
     * @notice Preview available LP fee yield
     * @return yieldUnderlying Yield in underlying asset units (18 decimals)
     * @return yieldGaugeShares Gauge shares that would be redeemed
     */
    function getAvailableLpFeeYield() external view returns (uint256 yieldUnderlying, uint256 yieldGaugeShares) {
        (uint256 trackedShares, uint256 depositedValue, uint256 currentValue) =
            ERC4626CollateralManager.getCollateral(address(_gauge), address(_lpToken));

        if (trackedShares == 0 || currentValue <= depositedValue) {
            return (0, 0);
        }

        yieldUnderlying = currentValue - depositedValue;
        yieldGaugeShares = (trackedShares * yieldUnderlying) / currentValue;
    }

    /**
     * @notice Get deposit info with underlying value
     */
    function getDepositInfo() external view returns (
        uint256 shares,
        uint256 depositedUnderlyingValue,
        uint256 currentUnderlyingValue
    ) {
        return ERC4626CollateralManager.getCollateral(address(_gauge), address(_lpToken));
    }
}
