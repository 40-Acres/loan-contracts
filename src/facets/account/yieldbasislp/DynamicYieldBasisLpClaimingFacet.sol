// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IYieldBasisGauge} from "../../../interfaces/IYieldBasisGauge.sol";
import {IYieldBasisLP} from "../../../interfaces/IYieldBasisLP.sol";
import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {DynamicYieldBasisCollateralManager} from "./DynamicYieldBasisCollateralManager.sol";

/**
 * @title DynamicYieldBasisLpClaimingFacet
 * @dev Claim gauge rewards and harvest LP trading-fee yield for YB markets
 *      backed by a live-debt-read vault.
 *
 *      Same flows as YieldBasisLpClaimingFacet; only the collateral-manager
 *      library used internally changes.
 */
contract DynamicYieldBasisLpClaimingFacet is AccessControl {
    using SafeERC20 for IERC20;

    PortfolioFactory public immutable _portfolioFactory;
    IYieldBasisGauge public immutable _gauge;
    IYieldBasisLP public immutable _lpToken;
    address public immutable _underlying;
    uint8 public immutable _underlyingDecimals;

    error ReentrantCall();

    // Shared with the lending facet so harvest cannot interleave with
    // borrow/repay flows on the same diamond.
    bytes32 private constant _LENDING_REENTRANCY_SLOT = keccak256("fortyacres.lending.reentrancy");

    modifier nonReentrant() {
        bytes32 slot = _LENDING_REENTRANCY_SLOT;
        uint256 status;
        assembly { status := sload(slot) }
        if (status == 2) revert ReentrantCall();
        assembly { sstore(slot, 2) }
        _;
        assembly { sstore(slot, 1) }
    }

    event GaugeRewardsClaimed(address indexed reward, uint256 amount);
    event LpFeesHarvested(uint256 gaugeSharesRedeemed, uint256 lpTokensBurned, uint256 underlyingReceived, address indexed owner);

    /// @dev `_underlying` is derived from `lendingPool.lendingAsset()` so collateral
    ///      pricing (LP pricePerShare) and debt comparisons share denomination by
    ///      construction.
    constructor(address portfolioFactory, address gauge, address lendingPool) {
        require(portfolioFactory != address(0), "Invalid portfolio factory");
        require(gauge != address(0), "Invalid gauge");
        require(lendingPool != address(0), "Invalid lending pool");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _gauge = IYieldBasisGauge(gauge);
        _lpToken = IYieldBasisLP(IYieldBasisGauge(gauge).asset());
        address asset = ILendingPool(lendingPool).lendingAsset();
        _underlying = asset;
        _underlyingDecimals = IERC20Metadata(asset).decimals();
    }

    function claimGaugeRewards(address reward) external onlyAuthorizedCaller(_portfolioFactory) returns (uint256 claimed) {
        claimed = _gauge.claim(reward, address(this));
        emit GaugeRewardsClaimed(reward, claimed);
    }

    function previewGaugeRewards(address reward) external view returns (uint256) {
        return _gauge.preview_claim(reward, address(this));
    }

    /**
     * @notice Harvest LP trading-fee yield (pricePerShare appreciation) by burning
     *         surplus LP for underlying. See YieldBasisLpClaimingFacet.harvestLpFees
     *         for the full step-by-step rationale; semantics identical here.
     */
    function harvestLpFees(uint256 minUnderlyingPerShare)
        external
        nonReentrant
        onlyAuthorizedCaller(_portfolioFactory)
        returns (uint256 underlyingReceived)
    {
        require(minUnderlyingPerShare > 0, "Zero slippage floor");

        uint256 ppsInUnderlying =
            (IYieldBasisLP(address(_lpToken)).pricePerShare() * (10 ** _underlyingDecimals)) / 1e18;
        require(minUnderlyingPerShare * 100 >= ppsInUnderlying * 85, "Slippage floor < 85%");

        address config = address(_portfolioFactory.portfolioFactoryConfig());
        address lpToken = address(_lpToken);
        address underlying = _underlying;
        address gauge = address(_gauge);

        DynamicYieldBasisCollateralManager.reconcileSharesToBalance(config, lpToken, underlying, gauge);

        (uint256 trackedShares, uint256 depositedValue, ) =
            DynamicYieldBasisCollateralManager.getCollateral(lpToken, underlying);
        uint256 currentValue = DynamicYieldBasisCollateralManager._resolveBasisValue(lpToken, trackedShares);

        require(trackedShares > 0, "No shares deposited");
        require(currentValue > depositedValue, "No yield to harvest");

        uint256 surplusShares = (trackedShares * (currentValue - depositedValue)) / currentValue;
        require(surplusShares > 0, "Yield too small to harvest");

        DynamicYieldBasisCollateralManager.removeSharesForYield(config, lpToken, underlying, surplusShares);

        uint256 directLp = IERC20(lpToken).balanceOf(address(this));
        uint256 lpToBurn;
        uint256 gaugeSharesBurned = 0;
        if (directLp >= surplusShares) {
            lpToBurn = surplusShares;
        } else {
            uint256 shortfall = surplusShares - directLp;
            gaugeSharesBurned = _gauge.withdraw(shortfall, address(this), address(this));
            uint256 delivered = IERC20(lpToken).balanceOf(address(this)) - directLp;
            lpToBurn = directLp + delivered;
        }

        uint256 minUnderlyingOut = (lpToBurn * minUnderlyingPerShare) / 1e18;
        IERC20(lpToken).approve(lpToken, lpToBurn);
        underlyingReceived = _lpToken.withdraw(lpToBurn, minUnderlyingOut, address(this));
        IERC20(lpToken).approve(lpToken, 0);

        DynamicYieldBasisCollateralManager.enforceCollateralRequirements(config, lpToken, underlying);

        emit LpFeesHarvested(gaugeSharesBurned, lpToBurn, underlyingReceived, _portfolioFactory.ownerOf(address(this)));
    }

    function getAvailableLpFeeYield() external view returns (uint256 yieldUnderlying, uint256 yieldGaugeShares) {
        address lpToken = address(_lpToken);
        (uint256 trackedShares, uint256 depositedValue,) =
            DynamicYieldBasisCollateralManager.getCollateral(lpToken, _underlying);

        uint256 actualLp = IERC20(lpToken).balanceOf(address(this));
        uint256 gaugeShares = IERC20(address(_gauge)).balanceOf(address(this));
        if (gaugeShares > 0) {
            actualLp += _gauge.convertToAssets(gaugeShares);
        }

        uint256 effectiveShares = trackedShares > actualLp ? actualLp : trackedShares;
        if (effectiveShares == 0) return (0, 0);

        uint256 effectiveDepositedValue = trackedShares > 0
            ? (depositedValue * effectiveShares) / trackedShares
            : 0;

        uint256 effectiveCurrentValue =
            DynamicYieldBasisCollateralManager._resolveBasisValue(lpToken, effectiveShares);

        if (effectiveCurrentValue <= effectiveDepositedValue) return (0, 0);

        // yieldGaugeShares is a share count; derive it from the 18-dec ratio
        // before denormalizing the value field so the units stay consistent.
        uint256 yield18d = effectiveCurrentValue - effectiveDepositedValue;
        yieldGaugeShares = (effectiveShares * yield18d) / effectiveCurrentValue;
        yieldUnderlying = _toUnderlying(yield18d);
    }

    /// @dev Value fields are in the underlying token's native decimals, matching
    ///      the ERC4626 collateral views. The share count is left as-is.
    function getDepositInfo() external view returns (
        uint256 shares,
        uint256 depositedUnderlyingValue,
        uint256 currentUnderlyingValue
    ) {
        (shares, depositedUnderlyingValue, currentUnderlyingValue) =
            DynamicYieldBasisCollateralManager.getCollateral(address(_lpToken), _underlying);
        depositedUnderlyingValue = _toUnderlying(depositedUnderlyingValue);
        currentUnderlyingValue = _toUnderlying(currentUnderlyingValue);
    }

    /// @dev Denormalize an 18-dec collateral value to the underlying's native
    ///      decimals. Inverse of the manager's internal 18-dec convention.
    function _toUnderlying(uint256 value18d) private view returns (uint256) {
        uint8 dec = _underlyingDecimals;
        if (dec < 18) return value18d / (10 ** (18 - dec));
        if (dec > 18) return value18d * (10 ** (dec - 18));
        return value18d;
    }
}
