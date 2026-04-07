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

    constructor(string memory name, string memory symbol, uint8 decimals_) MockERC20(name, symbol, decimals_) {
        _pricePerShare = 1e18; // 1:1 by default
    }

    function pricePerShare() external view returns (uint256) {
        return _pricePerShare;
    }

    function setPricePerShare(uint256 pps) external {
        _pricePerShare = pps;
    }

    function preview_withdraw(uint256 shares) external view returns (uint256) {
        return (shares * _pricePerShare) / 1e18;
    }

    function withdraw(uint256 shares, uint256 /*min_assets*/, address receiver) external returns (uint256 assets) {
        assets = (shares * _pricePerShare) / 1e18;
        _burn(msg.sender, shares);
        _mint(receiver, assets); // In real contract this returns underlying BTC, here we just simulate
        return assets;
    }
}
