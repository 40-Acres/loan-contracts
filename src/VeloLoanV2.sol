// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import { Loan } from "./LoanV2.sol";

contract VeloLoan is Loan {

        /* ORACLE */
    function confirmUsdcPrice() internal view override returns (bool) {
        (
            ,
            /* uint80 roundID */ int answer /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/,
            ,
            ,

        ) = AggregatorV3Interface(address(0x16a9FA2FDa030272Ce99B29CF780dFA30361E0f3)).latestRoundData();

        // confirm price of usdc is $1
        return answer >= 99900000;
    }
}