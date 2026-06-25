// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockPausableYieldBasisGauge
 * @dev Self-contained ERC4626-like YB gauge mock whose convertToAssets() reverts while
 *      `convertPaused` is set, simulating a paused / emergency-mode gauge. Gauge shares
 *      are 1:1 with the staked LP. The surface mirrors MockYieldBasisGauge but is not
 *      inherited so the pausable read does not need the base function to be virtual.
 *
 *      Used to prove that a reverting gauge convertToAssets on the repay path (the
 *      `_actualLp` ratchet read) must NOT block a repay, while a borrow under the same
 *      pause MUST still revert.
 */
contract MockPausableYieldBasisGauge is ERC20 {
    IERC20 public immutable _asset;
    bool public convertPaused;

    constructor(address asset_) ERC20("Mock Pausable Gauge", "mPGAUGE") {
        _asset = IERC20(asset_);
    }

    function setConvertPaused(bool paused_) external {
        convertPaused = paused_;
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        _asset.transferFrom(msg.sender, address(this), assets);
        shares = assets; // 1:1
        _mint(receiver, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 shares) {
        shares = assets; // 1:1
        _burn(owner_, shares);
        _asset.transfer(receiver, assets);
    }

    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256 assets) {
        assets = shares; // 1:1
        _burn(owner_, assets);
        _asset.transfer(receiver, assets);
    }

    function totalAssets() external view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    /// @dev Reverts when convertPaused; 1:1 otherwise.
    function convertToAssets(uint256 shares) external view returns (uint256) {
        require(!convertPaused, "paused");
        return shares; // 1:1
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets; // 1:1
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return assets; // 1:1
    }
}
