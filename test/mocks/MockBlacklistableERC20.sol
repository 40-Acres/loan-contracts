// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockERC20} from "./MockERC20.sol";

/**
 * @title MockBlacklistableERC20
 * @dev Mock ERC20 that reverts transfers to/from blacklisted addresses (like USDC/USDT).
 */
contract MockBlacklistableERC20 is MockERC20 {
    mapping(address => bool) public blacklisted;

    constructor(string memory name, string memory symbol, uint8 decimals_) MockERC20(name, symbol, decimals_) {}

    function setBlacklisted(address account, bool status) external {
        blacklisted[account] = status;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(!blacklisted[from], "Blacklisted sender");
        require(!blacklisted[to], "Blacklisted recipient");
        super._update(from, to, amount);
    }
}
