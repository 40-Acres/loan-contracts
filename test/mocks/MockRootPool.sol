// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IRootPool} from "../../src/interfaces/IRootPool.sol";

/**
 * @title MockRootPool
 * @dev Mock implementation of IRootPool for testing superchain voting.
 *      Real root pools live on Optimism and represent cross-chain liquidity.
 */
contract MockRootPool is IRootPool {
    uint256 private _chainid;

    constructor(uint256 chainId_) {
        _chainid = chainId_;
    }

    function chainid() external view override returns (uint256) {
        return _chainid;
    }
}
