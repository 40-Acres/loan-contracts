// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ILoanConfig} from "./ILoanConfig.sol";

/**
 * @title LoanConfig
 */
contract LoanConfig is ILoanConfig, Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    uint256 public constant MAX_FEE_BPS = 100_00; // 100% in basis points
    uint256 public constant DEFAULT_MAX_UTILIZATION_BPS = 8000;
    error TooHigh(uint256 value, uint256 max);
    error CombinedFeesTooHigh(uint256 combined, uint256 max);
    error InvalidMaxUtilization(uint256 value);
    error InvalidTreasury();
    error InvalidCurveBase(uint256 base, uint256 treasuryFee, uint256 max);
    error InvalidCurveCap(uint256 cap, uint256 treasuryFee, uint256 max);
    error InvalidCurveCapBelowBase(uint256 cap, uint256 base);
    error InvalidCurveSlope(uint256 slope, uint256 max);
    error InvalidCurveSlopeBelowExceedsSlope(uint256 slopeBelow, uint256 slope);

    /// @dev Sanity bound for the curve slope; ample headroom (1% premium added per 1bps ltv past kink at the top end).
    uint256 public constant MAX_LENDER_PREMIUM_SLOPE = MAX_FEE_BPS * 100;

    /// @dev Defensive clamp on the curve input. Per-borrower ltv can blow past 100%
    ///      (underwater positions); also `getLoanUtilization` returns `type(uint256).max`
    ///      when `maxLoanIgnoreSupply == 0`. Clamping here keeps the slope multiplication safe.
    uint256 public constant MAX_LENDER_PREMIUM_HEALTH_LTV_BPS = MAX_FEE_BPS * 100;

    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event LenderPremiumCurveUpdated(uint256 base, uint256 slope, uint256 kink, uint256 cap, uint256 slopeBelow);
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner, uint256 lenderPremium, uint256 treasuryFee, uint256 zeroBalanceFee) initializer public {
        __Ownable_init(owner);
        require(lenderPremium > 0, "Lender premium must be > 0");
        require(treasuryFee > 0, "Treasury fee must be > 0");
        require(zeroBalanceFee > 0, "Zero balance fee must be > 0");
        require(zeroBalanceFee <= MAX_FEE_BPS, "Zero balance fee cannot exceed max fee");
        uint256 combined = lenderPremium + treasuryFee;
        require(combined <= MAX_FEE_BPS, CombinedFeesTooHigh(combined, MAX_FEE_BPS));
        LoanConfigData storage config = _getLoanConfig();
        config.lenderPremium = lenderPremium;
        config.treasuryFee = treasuryFee;
        config.zeroBalanceFee = zeroBalanceFee;
    }
    
    /**
     * @dev This function is used to authorize upgrades to the contract.
     *      It restricts the upgradeability to only the contract owner.
     * @param newImplementation The address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    // Token storage data using named storage slot
    struct LoanConfigData {
        uint256 rewardsRate;
        uint256 lenderPremium;
        uint256 treasuryFee;
        uint256 zeroBalanceFee;
        uint256 multiplier;
        uint256 ltv;
        uint256 maxUtilizationBps;
        address treasury;
        uint256 lenderPremiumBase;
        uint256 lenderPremiumSlope;
        uint256 lenderPremiumKink;
        uint256 lenderPremiumCap;
        uint256 lenderPremiumSlopeBelow;
    }


    // Named storage slot for account data
    bytes32 private constant ACCOUNT_STORAGE_POSITION = keccak256("storage.LoanConfig");

    /**
     * @dev Get token storage data from named storage slot
     */
    function _getLoanConfig() internal pure returns (LoanConfigData storage collateralStorage) {
        bytes32 position = ACCOUNT_STORAGE_POSITION;
        assembly {
            collateralStorage.slot := position
        }
    }

    function getActiveRates() public view returns (uint256 lenderPremium, uint256 treasuryFee) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return (collateralStorage.lenderPremium, collateralStorage.treasuryFee);
    }

    function setRewardsRate(uint256 rewardsRate) public onlyOwner {
        LoanConfigData storage collateralStorage = _getLoanConfig();

        // require rewards rate is less than double the current rewards rate to prevent drastic changes
        // also take into account the rewards rate could be 0, so set a minimum rewards rate of 100 basis points (1%) to prevent division by zero errors in the rewards calculation
        if(collateralStorage.rewardsRate > 0) {
            require(rewardsRate <= collateralStorage.rewardsRate * 2, TooHigh(rewardsRate, collateralStorage.rewardsRate * 2));
        }
        collateralStorage.rewardsRate = rewardsRate;
    }

    function getRewardsRate() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.rewardsRate;
    }

    function setMultiplier(uint256 multiplier) public onlyOwner {
        LoanConfigData storage collateralStorage = _getLoanConfig();

        if(collateralStorage.multiplier > 0) {
            require(multiplier <= collateralStorage.multiplier * 2, TooHigh(multiplier, collateralStorage.multiplier * 2));
        }
        collateralStorage.multiplier = multiplier;
    }
    
    function setLtv(uint256 ltv) public onlyOwner {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        require(ltv <= MAX_FEE_BPS, "LTV cannot exceed max fee");
        collateralStorage.ltv = ltv;
    }

    function getLtv() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.ltv;
    }

    function getMultiplier() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.multiplier;
    }

    function setLenderPremium(uint256 lenderPremium) public onlyOwner {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        require(lenderPremium > 0, "Lender premium must be > 0");
        uint256 combined = lenderPremium + collateralStorage.treasuryFee;
        require(combined <= MAX_FEE_BPS, CombinedFeesTooHigh(combined, MAX_FEE_BPS));
        collateralStorage.lenderPremium = lenderPremium;
    }

    function getLenderPremium() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.lenderPremium;
    }

    /**
     * @notice Lender premium at a given per-borrower LTV (in bps).
     * @dev Input is the borrower's LTV as reported by `getLoanUtilization()`:
     *      100_00 = at-the-LTV-limit, >100_00 = underwater. This is not
     *      pool-level utilization (`loaned/totalSupplied`). The output is the
     *      percentage of incoming borrower rewards diverted to lenders, not an APR.
     *
     *      Curve disabled (both slopes `== 0`): returns the flat `lenderPremium`.
     *      Curve enabled: two-slope piecewise-linear with kink.
     *        ltv <= kink: base + slopeBelow * ltv / 100_00
     *        ltv >  kink: base + slopeBelow * kink / 100_00 + slope * (ltv - kink) / 100_00
     *      Output clamps to `cap`, or `MAX_FEE_BPS - treasuryFee` when `cap == 0`.
     *      Input is clamped to `MAX_LENDER_PREMIUM_HEALTH_LTV_BPS` to keep slope math safe.
     */
    function getLenderPremium(uint256 healthLtvBps) public view returns (uint256) {
        LoanConfigData storage c = _getLoanConfig();
        if (c.lenderPremiumSlope == 0 && c.lenderPremiumSlopeBelow == 0) return c.lenderPremium;

        if (healthLtvBps > MAX_LENDER_PREMIUM_HEALTH_LTV_BPS) healthLtvBps = MAX_LENDER_PREMIUM_HEALTH_LTV_BPS;

        uint256 kink = c.lenderPremiumKink;
        uint256 belowPortion = healthLtvBps < kink ? healthLtvBps : kink;
        uint256 rate = c.lenderPremiumBase + (c.lenderPremiumSlopeBelow * belowPortion) / 100_00;
        if (healthLtvBps > kink) {
            rate += (c.lenderPremiumSlope * (healthLtvBps - kink)) / 100_00;
        }

        uint256 effectiveCap = c.lenderPremiumCap == 0
            ? MAX_FEE_BPS - c.treasuryFee
            : c.lenderPremiumCap;
        if (rate > effectiveCap) rate = effectiveCap;

        return rate;
    }

    /**
     * @notice Set the lender-premium curve in one atomic call.
     * @dev Both slopes `== 0` is the implicit disable path: the flat `lenderPremium`
     *      remains in force regardless of base/kink/cap. `kink` is unbounded
     *      because it is an input axis (per-borrower LTV in bps), not a fee output.
     *      `slopeBelow` is the ramp below the kink, `slope` the ramp above; the
     *      curve must get steeper past the kink, so `slopeBelow <= slope`.
     */
    function setLenderPremiumCurve(uint256 base, uint256 slope, uint256 kink, uint256 cap, uint256 slopeBelow) public onlyOwner {
        LoanConfigData storage c = _getLoanConfig();
        uint256 treasuryFee_ = c.treasuryFee;

        if (base + treasuryFee_ > MAX_FEE_BPS) {
            revert InvalidCurveBase(base, treasuryFee_, MAX_FEE_BPS);
        }
        if (cap != 0) {
            if (cap + treasuryFee_ > MAX_FEE_BPS) {
                revert InvalidCurveCap(cap, treasuryFee_, MAX_FEE_BPS);
            }
            if (cap < base) revert InvalidCurveCapBelowBase(cap, base);
        }
        if (slope > MAX_LENDER_PREMIUM_SLOPE) {
            revert InvalidCurveSlope(slope, MAX_LENDER_PREMIUM_SLOPE);
        }
        if (slopeBelow > MAX_LENDER_PREMIUM_SLOPE) {
            revert InvalidCurveSlope(slopeBelow, MAX_LENDER_PREMIUM_SLOPE);
        }
        if (slopeBelow > slope) {
            revert InvalidCurveSlopeBelowExceedsSlope(slopeBelow, slope);
        }

        c.lenderPremiumBase = base;
        c.lenderPremiumSlope = slope;
        c.lenderPremiumKink = kink;
        c.lenderPremiumCap = cap;
        c.lenderPremiumSlopeBelow = slopeBelow;
        emit LenderPremiumCurveUpdated(base, slope, kink, cap, slopeBelow);
    }

    function getLenderPremiumCurve() public view returns (uint256 base, uint256 slope, uint256 kink, uint256 cap, uint256 slopeBelow) {
        LoanConfigData storage c = _getLoanConfig();
        return (c.lenderPremiumBase, c.lenderPremiumSlope, c.lenderPremiumKink, c.lenderPremiumCap, c.lenderPremiumSlopeBelow);
    }

    function setTreasuryFee(uint256 treasuryFee) public onlyOwner {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        require(treasuryFee > 0, "Treasury fee must be > 0");
        uint256 combined = collateralStorage.lenderPremium + treasuryFee;
        require(combined <= MAX_FEE_BPS, CombinedFeesTooHigh(combined, MAX_FEE_BPS));
        collateralStorage.treasuryFee = treasuryFee;
    }

    function getTreasuryFee() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.treasuryFee;
    }

    function setZeroBalanceFee(uint256 zeroBalanceFee) public onlyOwner {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        require(zeroBalanceFee > 0, "Zero balance fee must be > 0");
        require(zeroBalanceFee <= MAX_FEE_BPS, "Zero balance fee cannot exceed max fee");
        collateralStorage.zeroBalanceFee = zeroBalanceFee;
    }

    function getZeroBalanceFee() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.zeroBalanceFee;
    }

    function setMaxUtilizationBps(uint256 maxUtilizationBps) public onlyOwner {
        if (maxUtilizationBps == 0 || maxUtilizationBps > MAX_FEE_BPS) {
            revert InvalidMaxUtilization(maxUtilizationBps);
        }
        _getLoanConfig().maxUtilizationBps = maxUtilizationBps;
    }

    function getMaxUtilizationBps() public view returns (uint256) {
        uint256 stored = _getLoanConfig().maxUtilizationBps;
        return stored == 0 ? DEFAULT_MAX_UTILIZATION_BPS : stored;
    }

    function setTreasury(address treasury) public onlyOwner {
        if (treasury == address(0)) revert InvalidTreasury();
        LoanConfigData storage collateralStorage = _getLoanConfig();
        address old = collateralStorage.treasury;
        collateralStorage.treasury = treasury;
        emit TreasuryUpdated(old, treasury);
    }

    // @dev Returns the configured treasury; falls back to owner() when unset.
    function getTreasury() public view returns (address) {
        address t = _getLoanConfig().treasury;
        return t == address(0) ? owner() : t;
    }
}