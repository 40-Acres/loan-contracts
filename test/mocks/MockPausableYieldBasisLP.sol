// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {MockERC20} from "./MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockPausableYieldBasisLP
 * @dev Self-contained YB LP mock whose pricePerShare() and preview_withdraw() revert
 *      while `paused` is set, simulating a paused / emergency-mode YB LP market. The
 *      live surface mirrors MockTunableYieldBasisLP (pps + Curve-style withdraw) but is
 *      not inherited from it so the pausable reads do not need the base functions to be
 *      virtual.
 *
 *      Used to prove that a reverting YB market read on the repay path must NOT block a
 *      repay (which only reduces debt and never needs the borrow-side collateral read),
 *      while a borrow under the same pause MUST still revert.
 */
contract MockPausableYieldBasisLP is MockERC20 {
    IERC20 public immutable underlying;

    uint256 private _pricePerShare;
    uint256 public withdrawHaircutBps;
    bool public paused;

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        address underlying_
    ) MockERC20(name, symbol, decimals_) {
        require(underlying_ != address(0), "Underlying zero");
        underlying = IERC20(underlying_);
        _pricePerShare = 1e18;
    }

    function setPricePerShare(uint256 pps) external {
        _pricePerShare = pps;
    }

    function setWithdrawHaircutBps(uint256 bps) external {
        require(bps <= 10_000, "haircut > 100%");
        withdrawHaircutBps = bps;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    /// @dev Reverts when paused; 18-dec fair value otherwise.
    function pricePerShare() external view returns (uint256) {
        require(!paused, "paused");
        return _pricePerShare;
    }

    /// @dev Reverts when paused; Curve-style withdrawable otherwise.
    function preview_withdraw(uint256 shares) external view returns (uint256) {
        require(!paused, "paused");
        uint256 fair = (shares * _pricePerShare) / 1e18;
        return (fair * (10_000 - withdrawHaircutBps)) / 10_000;
    }

    /// @dev Burn `shares` LP, deliver underlying. Independent of `paused` so the
    ///      withdraw path itself is not what blocks under pause -- only the reads are.
    function withdraw(uint256 shares, uint256 min_assets, address receiver) external returns (uint256 assets) {
        uint256 fair = (shares * _pricePerShare) / 1e18;
        assets = (fair * (10_000 - withdrawHaircutBps)) / 10_000;
        require(assets >= min_assets, "min_assets");
        _burn(msg.sender, shares);
        if (assets > 0) {
            require(underlying.transfer(receiver, assets), "underlying transfer failed");
        }
    }
}
