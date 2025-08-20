// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Errors} from "./Errors.sol";

library SwapRouterLib {
    function enforceMinOut(uint256 beforeBalance, uint256 afterBalance, uint256 minOut) internal pure {
        if (afterBalance < beforeBalance + minOut) revert Errors.Slippage();
    }
}


