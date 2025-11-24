// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {IMarketOperatorFacet} from "../../interfaces/IMarketOperatorFacet.sol";

contract MarketOperatorFacet is IMarketOperatorFacet {
    function setOperatorApproval(address operator, bool approved) external {
        MarketStorage.orderbookLayout().isOperatorFor[msg.sender][operator] = approved;
        emit OperatorApproved(msg.sender, operator, approved);
    }
}


