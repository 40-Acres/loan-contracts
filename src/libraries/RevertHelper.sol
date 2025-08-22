// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library RevertHelper {
    function revertWithData(bytes memory returnData) internal pure {
        if (returnData.length > 0) {
            assembly {
                let returnDataSize := mload(returnData)
                revert(add(32, returnData), returnDataSize)
            }
        } else {
            revert("Call failed with no data");
        }
    }
}
