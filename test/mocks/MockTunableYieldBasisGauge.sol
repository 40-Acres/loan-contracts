// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockTunableYieldBasisGauge
 * @dev Mock ERC4626-like gauge for testing the H-003 fix in the YieldBasis LP
 *      collateral system. Lets tests configure non-1:1 share<->asset behavior
 *      so the production code's balance-delta measurement and reconcile path
 *      can be exercised without a fork.
 *
 *      Knobs (default 1:1 / no fee / exact rounding so it behaves identically
 *      to the simpler MockYieldBasisGauge unless explicitly tuned):
 *        - convertRatioBps: convertToAssets(shares) = shares * ratio / 10000
 *          (10_000 = 1:1, 9_900 = 1% drift down)
 *        - depositFeeBps: deposit(assets, ...) mints fewer gauge shares
 *          (gauge keeps the LP, mints `assets * (10000 - fee) / 10000`)
 *        - withdrawShortfallWei: withdraw(assets, ...) delivers `assets - n` LP
 *          (simulates a 1-wei-rounded ERC4626; revert-causing on a strict
 *           implementation that re-uses the input value as the LP amount)
 *        - redeemShortfallWei: redeem(shares, ...) delivers `shares - n` LP
 *          on top of any convertRatio (i.e. true assets returned = converted - n)
 *      Each knob is independent so tests can isolate the unit-conversion
 *      bug from the rounding bug.
 */
contract MockTunableYieldBasisGauge is ERC20 {
    IERC20 public immutable _asset;
    mapping(address => mapping(address => uint256)) public claimableRewards;

    uint256 public convertRatioBps = 10_000; // 10_000 = 1:1
    uint256 public depositFeeBps;            // 0 = no fee
    uint256 public withdrawShortfallWei;     // wei subtracted from delivered LP on withdraw
    uint256 public redeemShortfallWei;       // wei subtracted from delivered LP on redeem

    constructor(address asset_) ERC20("Mock Tunable Gauge", "mTGAUGE") {
        _asset = IERC20(asset_);
    }

    // ============ Test Configuration ============

    function setConvertRatioBps(uint256 bps) external {
        require(bps > 0 && bps <= 20_000, "ratio out of range");
        convertRatioBps = bps;
    }

    function setDepositFeeBps(uint256 bps) external {
        require(bps < 10_000, "fee too high");
        depositFeeBps = bps;
    }

    function setWithdrawShortfallWei(uint256 n) external { withdrawShortfallWei = n; }

    function setRedeemShortfallWei(uint256 n) external { redeemShortfallWei = n; }

    // ============ ERC4626-like Surface ============

    function asset() external view returns (address) {
        return address(_asset);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        _asset.transferFrom(msg.sender, address(this), assets);
        if (depositFeeBps == 0) {
            shares = assets;
        } else {
            shares = (assets * (10_000 - depositFeeBps)) / 10_000;
        }
        _mint(receiver, shares);
    }

    /**
     * @notice Withdraw `assets` LP; burn shares equivalent to that LP via
     *         convertRatioBps. Delivered LP is `assets - withdrawShortfallWei`
     *         to simulate ERC4626 1-wei rounding.
     */
    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 shares) {
        // Convert assets→shares via current ratio so non-1:1 gauges burn the
        // right share count for the LP requested.
        if (convertRatioBps == 10_000) {
            shares = assets;
        } else {
            // shares = assets * 10_000 / convertRatioBps (inverse of convertToAssets)
            shares = (assets * 10_000) / convertRatioBps;
        }
        _burn(owner_, shares);

        uint256 toDeliver = assets > withdrawShortfallWei ? assets - withdrawShortfallWei : 0;
        _asset.transfer(receiver, toDeliver);
    }

    /**
     * @notice Redeem `shares` for assets at current convertRatioBps, minus any
     *         redeemShortfallWei. Burns the full `shares`.
     */
    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256 assets) {
        // Apply convertRatio first
        if (convertRatioBps == 10_000) {
            assets = shares;
        } else {
            assets = (shares * convertRatioBps) / 10_000;
        }
        _burn(owner_, shares);

        uint256 toDeliver = assets > redeemShortfallWei ? assets - redeemShortfallWei : 0;
        _asset.transfer(receiver, toDeliver);
        // Return value reflects the converted amount (the value the redeem
        // *intended* to deliver) — the H-003 fix relies on the caller measuring
        // the actual balance delta, not trusting this return value.
        // Some 4626 impls return the delivered value; we return the converted
        // amount to make the bug behavior more conspicuous: tests that use the
        // return value as authoritative would mis-account.
    }

    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account);
    }

    function totalAssets() external view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        if (convertRatioBps == 10_000) return shares;
        return (shares * convertRatioBps) / 10_000;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        if (convertRatioBps == 10_000) return assets;
        return (assets * 10_000) / convertRatioBps;
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        if (convertRatioBps == 10_000) return assets;
        return (assets * 10_000) / convertRatioBps;
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

    function setClaimableRewards(address user, address reward, uint256 amount) external {
        claimableRewards[user][reward] = amount;
    }
}
