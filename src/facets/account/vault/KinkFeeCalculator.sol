// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IFeeCalculator} from "./IFeeCalculator.sol";


/**
 * @title KinkFeeCalculator
 * @notice Aave/Compound-style kinked rate model for DynamicFeesVault.
 * @dev Below U_TARGET: shallow linear ramp (BASE_FEE -> BASE_FEE + SLOPE_1).
 *      Above U_TARGET: steep linear ramp tracking towards a 100% cap.
 *      Output is the lender share in bps; borrower paydown = 10000 - rate.
 */
contract KinkFeeCalculator is IFeeCalculator {
    uint256 constant BPS         = 10_000;
    uint256 constant BASE_FEE    = 500;      // 5%   = 500 bps
    uint256 constant SLOPE_1     = 500;      // slope in bps per 100% util
    uint256 constant SLOPE_2     = 80_000;   // 800% per 100% util
    uint256 constant U_TARGET    = 7_500;    // 75%  = 7500 bps

    function getVaultRatioBps(uint256 utilizationBps) external pure override returns (uint256) {
        require(utilizationBps <= 10000, "Utilization exceeds 100%");

        if (utilizationBps <= U_TARGET) {
            return BASE_FEE + (SLOPE_1 * utilizationBps) / BPS;
        }
        uint256 rate = BASE_FEE
            + (SLOPE_1 * U_TARGET) / BPS
            + (SLOPE_2 * (utilizationBps - U_TARGET)) / BPS;

        return rate > 10_000 ? 10_000 : rate;
    }
}
