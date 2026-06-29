// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {MockERC20} from "./MockERC20.sol";

/**
 * @title MockYieldBasisLP
 * @dev Mock YieldBasis LP token for testing. Extends MockERC20 with pricePerShare().
 * pricePerShare is settable for testing fee appreciation scenarios.
 */
contract MockYieldBasisLP is MockERC20 {
    uint256 private _pricePerShare;

    // Decimals of the underlying the LP redeems into. pricePerShare is always
    // 18-dec; preview_withdraw/withdraw deliver in the underlying's native
    // decimals. Defaults to 18 so existing 18-dec markets are unchanged.
    uint8 private _underlyingDecimals = 18;

    constructor(string memory name, string memory symbol, uint8 decimals_) MockERC20(name, symbol, decimals_) {
        _pricePerShare = 1e18; // 1:1 by default
    }

    function pricePerShare() external view returns (uint256) {
        return _pricePerShare;
    }

    function setPricePerShare(uint256 pps) external {
        _pricePerShare = pps;
    }

    function setUnderlyingDecimals(uint8 dec) external {
        _underlyingDecimals = dec;
    }

    function preview_withdraw(uint256 shares) external view returns (uint256) {
        return _toUnderlying((shares * _pricePerShare) / 1e18);
    }

    function withdraw(uint256 shares, uint256 /*min_assets*/, address receiver) external returns (uint256 assets) {
        assets = _toUnderlying((shares * _pricePerShare) / 1e18);
        _burn(msg.sender, shares);
        _mint(receiver, assets); // In real contract this returns underlying BTC, here we just simulate
        return assets;
    }

    /// @dev Scale an 18-dec fair value to the underlying's native decimals.
    function _toUnderlying(uint256 fair18) internal view returns (uint256) {
        uint8 dec = _underlyingDecimals;
        if (dec < 18) return fair18 / (10 ** (18 - dec));
        if (dec > 18) return fair18 * (10 ** (dec - 18));
        return fair18;
    }
}
