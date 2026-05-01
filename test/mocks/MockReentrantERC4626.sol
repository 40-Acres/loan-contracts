// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockERC4626} from "./MockERC4626.sol";

/**
 * @title MockReentrantERC4626
 * @dev Mock ERC4626 that, when armed, re-enters a configured target on the
 *      first call to `redeem`. Used to verify that the `nonReentrant` modifier
 *      on `claimVaultYield` (and the shared lending slot) blocks cross-function
 *      reentry into `pay` / `claimVaultYield` / etc. on the same diamond.
 *
 *      Single-shot: armedOnce resets after the first re-entry attempt so the
 *      mock does not infinitely recurse. The inner call's revert (ReentrantCall)
 *      is bubbled up so tests can assert the exact selector.
 */
contract MockReentrantERC4626 is MockERC4626 {
    address public reentrancyTarget;
    bytes public reentrancyCalldata;
    bool public armedOnce;

    // Optional: scale down assets returned from redeem (in basis points, 10000 = 100%).
    // Used to test the absolute 85% floor.
    uint256 public redeemScaleBps = 10000;

    // Optional: force redeem to return a hardcoded value, ignoring previewRedeem.
    bool public forceRedeemReturn;
    uint256 public forcedRedeemAssets;

    // Optional: force previewRedeem to return zero (adversarial case).
    bool public forcePreviewRedeemZero;

    constructor(
        address asset_,
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) MockERC4626(asset_, name, symbol, decimals_) {}

    function arm(address target, bytes calldata data) external {
        reentrancyTarget = target;
        reentrancyCalldata = data;
        armedOnce = true;
    }

    function setRedeemScale(uint256 bps) external {
        redeemScaleBps = bps;
    }

    function setForceRedeemReturn(uint256 assets) external {
        forceRedeemReturn = true;
        forcedRedeemAssets = assets;
    }

    function setForcePreviewRedeemZero(bool v) external {
        forcePreviewRedeemZero = v;
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        if (forcePreviewRedeemZero) return 0;
        return super.previewRedeem(shares);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        // Trigger reentry BEFORE state mutation. The shared lending slot is
        // already set to "entered" by claimVaultYield, so this must revert.
        if (armedOnce && reentrancyTarget != address(0)) {
            armedOnce = false;
            (bool ok, bytes memory ret) = reentrancyTarget.call(reentrancyCalldata);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }

        // Fall through to a controlled implementation (mirrors MockERC4626.redeem
        // but applies optional scaling / forced return).
        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) {
                _approve(owner, msg.sender, allowed - shares);
            }
        }

        if (forceRedeemReturn) {
            assets = forcedRedeemAssets;
        } else {
            assets = (super.previewRedeem(shares) * redeemScaleBps) / 10000;
        }

        _burn(owner, shares);
        if (assets > 0) {
            // Pull from underlying balance held by this vault
            _safeTransferAsset(receiver, assets);
        }
    }

    function _safeTransferAsset(address to, uint256 amount) internal {
        // Use low-level call to avoid relying on `using SafeERC20` setup
        (bool ok, bytes memory ret) = address(asset()).call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "asset transfer failed");
    }
}
