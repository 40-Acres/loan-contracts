// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface ILendingVault is IERC4626 {
    function depositRewards(uint256 amount) external;

    /// @notice totalAssets() excluding assets deposited in the current block, so borrow
    ///         capacity cannot be inflated by a same-block (flash) deposit.
    function borrowableTotalAssets() external view returns (uint256);
}
