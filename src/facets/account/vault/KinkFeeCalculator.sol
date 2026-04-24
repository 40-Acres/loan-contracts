// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IFeeCalculator} from "./IFeeCalculator.sol";


contract FeeCalculator is IFeeCalculator {
    uint256 constant BPS         = 10_000;
    uint256 constant BASE_FEE    = 500;      // 5%   = 500 bps
    uint256 constant SLOPE_1     = 500;      // slope in bps per 100% util
    uint256 constant SLOPE_2     = 80_000;   // 800% per 100% util
    uint256 constant U_TARGET    = 7_500;    // 75%  = 7500 bps

    /**
     * @notice Calculates the vault ratio (fee percentage) based on utilization
     * @param utilizationBps The utilization rate in basis points (0-10000, where 10000 = 100%)
     * @return rate The vault ratio in basis points (e.g., 2000 = 20% fee to lenders)
     */
    function getVaultRatioBps(uint256 utilizationBps) external pure override returns (uint256 rate) {
    require(utilizationBps <= 10000, "Utilization exceeds 100%");

    if (utilizationBps <= U_TARGET) {
        return BASE_FEE + (SLOPE_1 * utilizationBps) / BPS;
    }
    return BASE_FEE
        + (SLOPE_1 * U_TARGET) / BPS
        + (SLOPE_2 * (utilizationBps - U_TARGET)) / BPS;
    }
}
