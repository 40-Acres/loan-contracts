// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockReentrantYieldBasisGauge
 * @dev ERC4626-like gauge that, when armed, re-enters a configured target during
 *      `withdraw`. Used to verify the `nonReentrant` modifier on
 *      `YieldBasisLpClaimingFacet.harvestLpFees` actually reverts a malicious
 *      gauge attempting to call back into harvest mid-execution.
 *
 *      Single-shot: `armedOnce` resets to false after the first re-entry attempt
 *      so the mock won't infinitely recurse if the guard is missing.
 */
contract MockReentrantYieldBasisGauge is ERC20 {
    IERC20 public immutable _asset;
    mapping(address => mapping(address => uint256)) public claimableRewards;

    address public reentrancyTarget;
    bytes public reentrancyCalldata;
    bool public armedOnce;

    constructor(address asset_) ERC20("Mock Reentrant Gauge", "mRGAUGE") {
        _asset = IERC20(asset_);
    }

    function arm(address target, bytes calldata data) external {
        reentrancyTarget = target;
        reentrancyCalldata = data;
        armedOnce = true;
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        _asset.transferFrom(msg.sender, address(this), assets);
        shares = assets;
        _mint(receiver, shares);
    }

    /// @dev Re-enters target before delivering LP. If `nonReentrant` on the
    ///      target is correctly wired, the inner call reverts and bubbles up.
    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 shares) {
        if (armedOnce && reentrancyTarget != address(0)) {
            armedOnce = false;
            (bool ok, bytes memory ret) = reentrancyTarget.call(reentrancyCalldata);
            if (!ok) {
                // Bubble the revert out so the test can assert on the inner reason.
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        shares = assets;
        _burn(owner_, shares);
        _asset.transfer(receiver, assets);
    }

    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256 assets) {
        assets = shares;
        _burn(owner_, shares);
        _asset.transfer(receiver, assets);
    }

    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account);
    }

    function totalAssets() external view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return assets;
    }

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

    function setClaimableRewards(address user, address reward, uint256 amount) external {
        claimableRewards[user][reward] = amount;
    }
}
