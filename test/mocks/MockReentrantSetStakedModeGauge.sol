// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockReentrantSetStakedModeGauge
 * @dev ERC4626-like gauge mock used to verify the `nonReentrant` modifier on
 *      `YieldBasisLpFacet.setStakedMode`. Re-enters the configured target on
 *      either `deposit` (staked=true path) or `redeem` (staked=false path).
 *
 *      Each surface is independently armable so a single test contract can
 *      run both flows without the prior arm leaking. After firing once the
 *      mock disarms — if the nonReentrant guard is missing this prevents
 *      infinite recursion from masking the assertion.
 */
contract MockReentrantSetStakedModeGauge is ERC20 {
    IERC20 public immutable _asset;

    address public reentrancyTarget;
    bytes public reentrancyCalldata;
    bool public armedOnDeposit;
    bool public armedOnRedeem;

    constructor(address asset_) ERC20("Mock Reentrant Stake Gauge", "mRSGAUGE") {
        _asset = IERC20(asset_);
    }

    function armOnDeposit(address target, bytes calldata data) external {
        reentrancyTarget = target;
        reentrancyCalldata = data;
        armedOnDeposit = true;
    }

    function armOnRedeem(address target, bytes calldata data) external {
        reentrancyTarget = target;
        reentrancyCalldata = data;
        armedOnRedeem = true;
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    /// @dev Re-enters target BEFORE doing the deposit accounting. This way
    ///      the outer setStakedMode call is mid-flight (still inside
    ///      nonReentrant) when the callback fires.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        if (armedOnDeposit && reentrancyTarget != address(0)) {
            armedOnDeposit = false;
            (bool ok, bytes memory ret) = reentrancyTarget.call(reentrancyCalldata);
            if (!ok) {
                assembly { revert(add(ret, 32), mload(ret)) }
            }
        }
        _asset.transferFrom(msg.sender, address(this), assets);
        shares = assets;
        _mint(receiver, shares);
    }

    /// @dev Re-enters target during redeem (the staked=false path).
    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256 assets) {
        if (armedOnRedeem && reentrancyTarget != address(0)) {
            armedOnRedeem = false;
            (bool ok, bytes memory ret) = reentrancyTarget.call(reentrancyCalldata);
            if (!ok) {
                assembly { revert(add(ret, 32), mload(ret)) }
            }
        }
        assets = shares;
        _burn(owner_, shares);
        _asset.transfer(receiver, assets);
    }

    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 shares) {
        shares = assets;
        _burn(owner_, shares);
        _asset.transfer(receiver, assets);
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
}
