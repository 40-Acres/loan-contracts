// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockYieldBasisGauge
 * @dev Mock ERC4626-like gauge for testing YieldBasisLpFacet.
 * Gauge shares are 1:1 with the underlying ybBTC token.
 * Tracks claimable rewards per user for testing claim flows.
 */
contract MockYieldBasisGauge is ERC20 {
    IERC20 public immutable _asset;
    mapping(address => mapping(address => uint256)) public claimableRewards;

    constructor(address asset_) ERC20("Mock Gauge", "mGAUGE") {
        _asset = IERC20(asset_);
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

    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account);
    }

    function totalAssets() external view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    // ============ ERC4626 Compatibility (for ERC4626CollateralManager) ============

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares; // 1:1
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets; // 1:1
    }

    // ============ Reward Mechanics ============

    function claim(address reward, address user) external returns (uint256 amount) {
        amount = claimableRewards[user][reward];
        claimableRewards[user][reward] = 0;
        if (amount > 0) {
            IERC20(reward).transfer(user, amount);
        }
    }

    function preview_claim(address reward, address user) external view returns (uint256) {
        return claimableRewards[user][reward];
    }

    // ============ Test Helpers ============

    function setClaimableRewards(address user, address reward, uint256 amount) external {
        claimableRewards[user][reward] = amount;
    }
}
