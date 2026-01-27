// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IFeeCalculator} from "./IFeeCalculator.sol";

/**
 * @title FeeCalculator
 * @notice Default fee curve calculator for DebtToken
 * @dev Implements a piecewise quadratic fee curve:
 *      - 0-10% utilization: 5% to 20% fee (quadratic)
 *      - 10-70% utilization: 20% fee (flat)
 *      - 70-90% utilization: 20% to 40% fee (quadratic)
 *      - 90-100% utilization: 40% to 95% fee (steep quadratic)
 */
contract FeeCalculator is IFeeCalculator {
    uint256 public constant PRECISION = 1e18;

    /**
     * @notice Calculates the vault ratio (fee percentage) based on utilization
     * @param utilizationBps The utilization rate in basis points (0-10000, where 10000 = 100%)
     * @return rate The vault ratio in basis points (e.g., 2000 = 20% fee to lenders)
     */
    function getVaultRatioBps(uint256 utilizationBps) external pure override returns (uint256 rate) {
        require(utilizationBps <= 10000, "Utilization exceeds 100%");

        if (utilizationBps <= 1000) {
            // 0-10%: Quadratic curve from 500 to 2000 bps (5% to 20%)
            uint256 t = (utilizationBps * PRECISION) / 1000;
            rate = 500 + (1500 * t * t) / (PRECISION * PRECISION);
        } else if (utilizationBps <= 7000) {
            // 10-70%: Flat at 2000 bps (20%)
            rate = 2000;
        } else if (utilizationBps <= 9000) {
            // 70-90%: Gradual quadratic curve from 2000 to 4000 bps (20% to 40%)
            uint256 segment = utilizationBps - 7000;
            uint256 t = (segment * PRECISION) / 2000;
            rate = 2000 + (2000 * t * t) / (PRECISION * PRECISION);
        } else {
            // 90-100%: Steep quadratic curve from 4000 to 9500 bps (40% to 95%)
            uint256 segment = utilizationBps - 9000;
            uint256 t = (segment * PRECISION) / 1000;
            rate = 4000 + (5500 * t * t) / (PRECISION * PRECISION);
        }

        return rate;
    }
}
