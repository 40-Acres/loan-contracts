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
    uint8 public immutable _underlyingDecimals;

    error ReentrantCall();

    // Reuse the lending facet's reentrancy slot — harvest is debt-aware (it
    // mutates collateral tracking that lending depends on) and must not
    // interleave with borrow/repay flows on the same diamond.
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
    ///      construction. The operator cannot pass a mismatched `underlying` arg.
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
     * @notice Harvest LP trading-fee yield (pricePerShare appreciation) by burning
     *         surplus LP for underlying. Underlying is left on the portfolio account
     *         for downstream RewardsProcessingFacet routing.
     *
     * @dev Flow:
     *      1. Reconcile tracked shares to actual recoverable LP. Gauge skim and
     *         ERC4626 rounding can only reduce the recoverable amount; reconcile
     *         is one-way (never extends). This is the safety invariant — without
     *         it the surplus calc would treat skim-eroded shares as if they still
     *         held their original principal, leaking principal as "yield."
     *      2. surplusShares = trackedShares × (currentValue − depositedValue) /
     *         currentValue. Per-share basis is preserved across the burn so
     *         depositedAssetValue stays invariant in real terms.
     *      3a. Deduct from collateral tracking via removeSharesForYield —
     *          proportional basis deduction + absolute LTV check.
     *      3b. Source surplus LP physically — prefer direct LP balance (no gauge
     *          fee), fall back to _gauge.withdraw for the shortfall. Measure
     *          delivered LP via balance delta; never trust ERC4626 return values.
     *      4. Burn LP for underlying via _lpToken.withdraw with the slippage floor.
     *      5. enforceCollateralRequirements as defense-in-depth. The absolute LTV
     *         check inside removeSharesForYield already covers this exact path
     *         (LP burn doesn't mutate collateral or debt tracking), but the
     *         delta-shortfall guard is kept to catch future maintainers adding
     *         a state-mutating call between the burn and function exit.
     *
     * @dev Oracle posture: trusts IYieldBasisLP.pricePerShare() to be the YB
     *      protocol's stated "non-manipulatable fair price" oracle. If a future
     *      YB pool exposes a spot-derived pricePerShare, the surplus computation
     *      and basis preservation are only as honest as that price feed.
     *
     * @param minUnderlyingPerShare Minimum underlying-native wei delivered per
     *        1.0 LP burned (per 1e18 LP wei). Caller pre-scales to the
     *        underlying's own decimals. Examples:
     *          - WETH (18d): pass 0.99e18 → require ≥ 0.99 WETH per LP.
     *          - cbBTC (8d): pass 0.99e8  → require ≥ 0.99 cbBTC per LP.
     *        Enforced as: minUnderlyingOut = (lpToBurn × minUnderlyingPerShare) / 1e18.
     *
     * @dev WARNING — Curve-burn haircut: _lpToken.withdraw routes through the
     *      underlying Curve pool and incurs an imbalance fee + pool-state
     *      slippage strictly worse than the pricePerShare-implied rate
     *      (mainnet: up to ~26% during volatile blocks). Callers MUST size
     *      minUnderlyingPerShare from a fresh IYieldBasisLP.preview_withdraw
     *      quote, NOT from pricePerShare × tolerance. The contract enforces an
     *      85% floor against pricePerShare to reject obviously-broken callers,
     *      but a tighter caller-side floor sized to current Curve depth is
     *      required for real protection.
     *
     * @return underlyingReceived Underlying delivered to the account (post-haircut).
     */
    function harvestLpFees(uint256 minUnderlyingPerShare)
        external
        nonReentrant
        onlyAuthorizedCaller(_portfolioFactory)
        returns (uint256 underlyingReceived)
    {
        require(minUnderlyingPerShare > 0, "Zero slippage floor");

        // 85% floor against pricePerShare. Rejects callers that would silently
        // accept >15% Curve haircut. Tighter caller-side floors must come from
        // the off-chain preview_withdraw quote.
        uint256 ppsInUnderlying =
            (IYieldBasisLP(address(_lpToken)).pricePerShare() * (10 ** _underlyingDecimals)) / 1e18;
        require(minUnderlyingPerShare * 100 >= ppsInUnderlying * 85, "Slippage floor < 85%");

        address config = address(_portfolioFactory.portfolioFactoryConfig());
        address lpToken = address(_lpToken);
        address underlying = _underlying;
        address gauge = address(_gauge);

        // Step 1: reconcile-first — accounting truth boundary.
        YieldBasisCollateralManager.reconcileSharesToBalance(config, lpToken, underlying, gauge);

        // Step 2: read post-reconcile state and validate yield exists.
        // Surplus uses pps-priced basis on both sides so real pps growth always
        // unblocks harvest (and thus lender-premium flow) regardless of pool
        // TRD. The collateral mark for LTV/liquidation uses min() separately.
        (uint256 trackedShares, uint256 depositedValue, ) =
            YieldBasisCollateralManager.getCollateral(lpToken, underlying);
        uint256 currentValue = YieldBasisCollateralManager._resolveBasisValue(lpToken, trackedShares);

        require(trackedShares > 0, "No shares deposited");
        require(currentValue > depositedValue, "No yield to harvest");

        uint256 surplusShares = (trackedShares * (currentValue - depositedValue)) / currentValue;
        require(surplusShares > 0, "Yield too small to harvest");

        // Step 3a: deduct from collateral tracking with proportional basis preservation.
        // Internal absolute LTV check fires here — harvest cannot push debt past max-loan.
        YieldBasisCollateralManager.removeSharesForYield(config, lpToken, underlying, surplusShares);

        // Step 3b: source surplus LP — prefer direct balance, fall back to gauge.
        uint256 directLp = IERC20(lpToken).balanceOf(address(this));
        uint256 lpToBurn;
        uint256 gaugeSharesBurned = 0;
        if (directLp >= surplusShares) {
            lpToBurn = surplusShares;
        } else {
            uint256 shortfall = surplusShares - directLp;
            gaugeSharesBurned = _gauge.withdraw(shortfall, address(this), address(this));
            uint256 delivered = IERC20(lpToken).balanceOf(address(this)) - directLp;
            // If the gauge under-delivers due to ERC4626 rounding, data.shares ends
            // up at most 1 wei above actual recoverable LP. Next harvest's
            // reconcile-first absorbs the discrepancy.
            lpToBurn = directLp + delivered;
        }

        // Step 4: burn LP for underlying with slippage floor.
        uint256 minUnderlyingOut = (lpToBurn * minUnderlyingPerShare) / 1e18;
        IERC20(lpToken).approve(lpToken, lpToBurn);
        underlyingReceived = _lpToken.withdraw(lpToBurn, minUnderlyingOut, address(this));
        IERC20(lpToken).approve(lpToken, 0);

        // Step 5: defense-in-depth delta-shortfall guard.
        YieldBasisCollateralManager.enforceCollateralRequirements(config, lpToken, underlying);

        emit LpFeesHarvested(gaugeSharesBurned, lpToBurn, underlyingReceived, _portfolioFactory.ownerOf(address(this)));
    }

    /**
     * @notice Preview LP fee yield harvestLpFees would deliver.
     * @dev Mirrors the action: pps-priced surplus on both sides. Returned value
     *      is fair (EMA) yield; realized underlying after the Curve burn will
     *      be lower by the pool's imbalance haircut, bounded by the slippage
     *      floor the caller passes.
     */
    function getAvailableLpFeeYield() external view returns (uint256 yieldUnderlying, uint256 yieldGaugeShares) {
        address lpToken = address(_lpToken);
        (uint256 trackedShares, uint256 depositedValue,) =
            YieldBasisCollateralManager.getCollateral(lpToken, _underlying);

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
            YieldBasisCollateralManager._resolveBasisValue(lpToken, effectiveShares);

        if (effectiveCurrentValue <= effectiveDepositedValue) return (0, 0);

        // yieldGaugeShares is a share count; derive it from the 18-dec ratio
        // before denormalizing the value field so the units stay consistent.
        uint256 yield18d = effectiveCurrentValue - effectiveDepositedValue;
        yieldGaugeShares = (effectiveShares * yield18d) / effectiveCurrentValue;
        yieldUnderlying = _toUnderlying(yield18d);
    }

    /**
     * @notice Get deposit info with underlying value (raw storage read; no reconcile simulation)
     * @dev Value fields are in the underlying token's native decimals, matching
     *      the ERC4626 collateral views. The share count is left as-is.
     */
    function getDepositInfo() external view returns (
        uint256 shares,
        uint256 depositedUnderlyingValue,
        uint256 currentUnderlyingValue
    ) {
        (shares, depositedUnderlyingValue, currentUnderlyingValue) =
            YieldBasisCollateralManager.getCollateral(address(_lpToken), _underlying);
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
