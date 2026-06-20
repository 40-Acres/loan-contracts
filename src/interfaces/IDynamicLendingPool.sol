// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ILendingPool} from "./ILendingPool.sol";

/// @notice Lending pool exposing a conservative outstanding-capital read for borrow caps.
/// @dev Implemented by DynamicFeesVault. activeAssetsConservative() excludes unsettled
///      borrower reward credit, so getMaxLoan never over-states borrow headroom.
interface IDynamicLendingPool is ILendingPool {
    function activeAssetsConservative() external view returns (uint256);
}
