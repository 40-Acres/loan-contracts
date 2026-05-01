// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IYieldBasisLP} from "../../../../src/interfaces/IYieldBasisLP.sol";

/**
 * @title HarvestFloor85
 * @dev Shared helper for harvest tests. The production claiming facet rejects
 *      `minUnderlyingPerShare` strictly below 85% of the LP's current
 *      `pricePerShare()`. Tests that don't care about the floor itself —
 *      they're exercising other code paths — use this helper to compute the
 *      smallest acceptable value, scaled to an 18-decimal underlying.
 *
 *      For non-18-dec underlyings, callers must scale by 10**dec / 1e18.
 *      This helper is intentionally underlying-agnostic at the LP layer
 *      (returns a 1e18-scaled value) so callers can compose freely.
 */
abstract contract HarvestFloor85 {
    /// @dev Returns 85% of the LP's current pricePerShare (1e18-scaled).
    function _floor85(IYieldBasisLP lp) internal view returns (uint256) {
        return (lp.pricePerShare() * 85) / 100;
    }
}
