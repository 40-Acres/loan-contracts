// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockERC4626} from "./MockERC4626.sol";

/**
 * @title MockExitFeeERC4626
 * @dev ERC4626 mock that applies a configurable exit fee (in bps) to previewRedeem.
 *      convertToAssets still returns the un-haircut value so that
 *      previewRedeem(s) < convertToAssets(s) whenever exitFeeBps > 0,
 *      matching a real vault that charges a redemption fee.
 */
contract MockExitFeeERC4626 is MockERC4626 {
    uint16 public exitFeeBps;

    constructor(
        address asset_,
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) MockERC4626(asset_, name, symbol, decimals_) {}

    function setExitFeeBps(uint16 newExitFeeBps) external {
        require(newExitFeeBps <= 10_000, "exitFeeBps > 10000");
        exitFeeBps = newExitFeeBps;
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 ideal = convertToAssets(shares);
        if (exitFeeBps == 0) return ideal;
        return (ideal * (10_000 - exitFeeBps)) / 10_000;
    }
}
