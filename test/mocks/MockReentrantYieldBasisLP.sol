// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {MockERC20} from "./MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockReentrantYieldBasisLP
 * @dev YieldBasis-LP-shaped mock that, when armed, re-enters a configured target
 *      during `withdraw`. Used to verify `nonReentrant` covers the LP-side
 *      external call in `harvestLpFees` (step 4: `_lpToken.withdraw(...)`).
 *
 *      Single-shot: `armedOnce` resets after the first re-entry attempt so the
 *      mock does not infinitely recurse.
 */
contract MockReentrantYieldBasisLP is MockERC20 {
    IERC20 public immutable underlying;
    uint256 private _pricePerShare;

    address public reentrancyTarget;
    bytes public reentrancyCalldata;
    bool public armedOnce;

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

    function arm(address target, bytes calldata data) external {
        reentrancyTarget = target;
        reentrancyCalldata = data;
        armedOnce = true;
    }

    function pricePerShare() external view returns (uint256) {
        return _pricePerShare;
    }

    function preview_withdraw(uint256 shares) external view returns (uint256) {
        return (shares * _pricePerShare) / 1e18;
    }

    /// @dev Re-enters target before delivering underlying. The inner call
    ///      should hit `nonReentrant` and revert; we bubble that revert up.
    function withdraw(uint256 shares, uint256 min_assets, address receiver) external returns (uint256 assets) {
        if (armedOnce && reentrancyTarget != address(0)) {
            armedOnce = false;
            (bool ok, bytes memory ret) = reentrancyTarget.call(reentrancyCalldata);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }

        assets = (shares * _pricePerShare) / 1e18;
        require(assets >= min_assets, "min_assets");
        _burn(msg.sender, shares);
        if (assets > 0) {
            require(underlying.transfer(receiver, assets), "underlying transfer failed");
        }
    }
}
