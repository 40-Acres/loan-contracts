// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title ResetDebtCounterFacet
 * @dev One-shot facet to zero out stale undercollateralizedDebt and overSuppliedVaultDebt
 *      counters on CollateralManager storage. Deploy, register, call, then remove from
 *      the FacetRegistry in one transaction. No lingering admin methods on the diamond.
 */
contract ResetDebtCounterFacet {

    struct CollateralManagerData {
        mapping(uint256 => uint256) lockedCollaterals;
        mapping(uint256 => uint256) originTimestamps;
        uint256 totalLockedCollateral;
        uint256 debt;
        uint256 overSuppliedVaultDebt;
        uint256 undercollateralizedDebt;
    }

    function resetDebtCounters() external {
        bytes32 position = keccak256("storage.CollateralManager");
        CollateralManagerData storage data;
        assembly {
            data.slot := position
        }
        data.undercollateralizedDebt = 0;
        data.overSuppliedVaultDebt = 0;
    }
}
