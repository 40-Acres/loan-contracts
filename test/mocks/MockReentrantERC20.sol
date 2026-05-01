// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockERC20} from "./MockERC20.sol";

/**
 * @title MockReentrantERC20
 * @dev ERC20 mock that, when armed, re-enters a configured target on
 *      `transferFrom`. Used to verify `pay()`'s `nonReentrant` modifier
 *      blocks reentry that occurs during the lending-token pull.
 *
 *      Single-shot: armedOnce resets after the first re-entry attempt to avoid
 *      infinite recursion. The inner revert is bubbled up.
 */
contract MockReentrantERC20 is MockERC20 {
    address public reentrancyTarget;
    bytes public reentrancyCalldata;
    bool public armedOnce;

    constructor(string memory name, string memory symbol, uint8 decimals_)
        MockERC20(name, symbol, decimals_)
    {}

    function arm(address target, bytes calldata data) external {
        reentrancyTarget = target;
        reentrancyCalldata = data;
        armedOnce = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armedOnce && reentrancyTarget != address(0)) {
            armedOnce = false;
            (bool ok, bytes memory ret) = reentrancyTarget.call(reentrancyCalldata);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        return super.transferFrom(from, to, amount);
    }
}
