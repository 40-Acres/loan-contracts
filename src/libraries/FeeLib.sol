// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MarketStorage} from "../libraries/storage/MarketStorage.sol";
import {RouteLib} from "../libraries/RouteLib.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

library FeeLib {
    using SafeERC20 for IERC20;

    // calculate fee amount based on type of transaction and total amount
    // input: type of transaction, total amount which are used to lookup feeBps and return fee amount
    // output: fee amount
    function calculateFee(RouteLib.BuyRoute routeType, uint256 amount) internal view returns (uint256) {
        // get fee bps from config
        uint16 feeBps = MarketStorage.configLayout().feeBps[routeType];
        if (feeBps == 0 || amount == 0) return 0;
        return (amount * feeBps) / 10000;
    }

    // get fee recipient from config
    // output: fee recipient
    function feeRecipient() internal view returns (address) {
        return MarketStorage.configLayout().feeRecipient;
    }
}


