// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IYieldBasisGauge} from "../../../interfaces/IYieldBasisGauge.sol";
import {IYieldBasisLP} from "../../../interfaces/IYieldBasisLP.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {YieldBasisCollateralManager} from "./YieldBasisCollateralManager.sol";

/**
 * @title YieldBasisLpClaimingFacet
 * @dev Claims value out of the YieldBasis gauge position:
 *      - Gauge reward tokens (e.g. YB emissions) via claimGaugeRewards
 *      - LP trading-fee appreciation (pricePerShare yield) via harvestLpFees
 *
 * Both flows leave output tokens on the portfolio account for further processing
 * (e.g. by RewardsProcessingFacet).
 */
contract YieldBasisLpClaimingFacet is AccessControl {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    IYieldBasisGauge public immutable _gauge;
    IYieldBasisLP public immutable _lpToken;
    address public immutable _underlying;

    event GaugeRewardsClaimed(address indexed reward, uint256 amount);
    event LpFeesHarvested(uint256 gaugeSharesRedeemed, uint256 lpTokensBurned, uint256 underlyingReceived, address indexed owner);

    constructor(address portfolioFactory, address gauge, address underlying) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(gauge != address(0), "Invalid gauge");
        require(underlying != address(0), "Invalid underlying");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _gauge = IYieldBasisGauge(gauge);
        _lpToken = IYieldBasisLP(IYieldBasisGauge(gauge).asset());
        _underlying = underlying;
    }

    // ============ Gauge Reward Claiming ============

    /**
     * @notice Claim reward tokens from the YieldBasis gauge
     * @param reward The reward token to claim (e.g. YB token address)
     * @return claimed Amount of reward tokens claimed
     */
    function claimGaugeRewards(address reward) external onlyAuthorizedCaller(_portfolioFactory) returns (uint256 claimed) {
        claimed = _gauge.claim(reward, address(this));
        emit GaugeRewardsClaimed(reward, claimed);
    }

    /**
     * @notice Preview claimable reward tokens from the gauge
     * @param reward The reward token to query
     * @return Amount of reward tokens claimable
     */
    function previewGaugeRewards(address reward) external view returns (uint256) {
        return _gauge.preview_claim(reward, address(this));
    }

    // ============ LP Trading-Fee Harvesting ============

    /**
     * @notice Harvest LP trading fee yield (pricePerShare appreciation)
     * @dev Redeems surplus gauge shares, withdraws LP tokens for underlying asset.
     *      Underlying asset stays on the portfolio account for RewardsProcessingFacet.
     * @param minUnderlyingOut Minimum underlying asset to receive (slippage protection)
     * @return underlyingReceived Amount of underlying asset harvested
     */
    function harvestLpFees(uint256 minUnderlyingOut) external onlyAuthorizedCaller(_portfolioFactory) returns (uint256 underlyingReceived) {
        address config = address(_portfolioFactory.portfolioFactoryConfig());
        address lpToken = address(_lpToken);
        address underlying = _underlying;

        (uint256 trackedShares, uint256 depositedValue, uint256 currentValue) =
            YieldBasisCollateralManager.getCollateral(lpToken, underlying);

        require(trackedShares > 0, "No shares deposited");
        require(currentValue > depositedValue, "No yield to harvest");

        uint256 surplusShares = (trackedShares * (currentValue - depositedValue)) / currentValue;
        require(surplusShares > 0, "Yield too small to harvest");

        YieldBasisCollateralManager.removeSharesForYield(config, lpToken, underlying, surplusShares);

        uint256 lpReceived = _gauge.withdraw(surplusShares, address(this), address(this));

        IERC20(lpToken).approve(lpToken, lpReceived);
        underlyingReceived = _lpToken.withdraw(lpReceived, minUnderlyingOut, address(this));
        IERC20(lpToken).approve(lpToken, 0);

        YieldBasisCollateralManager.enforceCollateralRequirements(config, lpToken, underlying);

        emit LpFeesHarvested(surplusShares, lpReceived, underlyingReceived, _portfolioFactory.ownerOf(address(this)));
    }

    /**
     * @notice Preview available LP fee yield
     * @return yieldUnderlying Yield in underlying asset units (18 decimals)
     * @return yieldGaugeShares Gauge shares that would be redeemed
     */
    function getAvailableLpFeeYield() external view returns (uint256 yieldUnderlying, uint256 yieldGaugeShares) {
        (uint256 trackedShares, uint256 depositedValue, uint256 currentValue) =
            YieldBasisCollateralManager.getCollateral(address(_lpToken), _underlying);

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
        return YieldBasisCollateralManager.getCollateral(address(_lpToken), _underlying);
    }
}
