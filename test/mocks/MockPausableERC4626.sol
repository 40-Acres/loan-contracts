// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockERC4626} from "./MockERC4626.sol";

/**
 * @title MockPausableERC4626
 * @dev MockERC4626 variant whose previewRedeem reverts while a `paused` flag is set,
 *      simulating a paused / emergency-mode collateral vault. All other behavior
 *      (deposit/withdraw/redeem/conversions) is inherited unchanged so the harness
 *      setup continues to function while unpaused.
 *
 *      Used to prove that a reverting collateral previewRedeem must NOT block a repay
 *      (which only reduces debt and never needs the borrow-side collateral read).
 */
contract MockPausableERC4626 is MockERC4626 {
    bool public paused;

    constructor(
        address asset_,
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) MockERC4626(asset_, name, symbol, decimals_) {}

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    /// @dev Reverts when paused; identical to MockERC4626 otherwise.
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        require(!paused, "paused");
        return super.previewRedeem(shares);
    }
}
