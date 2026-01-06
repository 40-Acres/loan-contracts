// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import { Loan } from "./LoanV2.sol";

contract VeloLoan is Loan {

        /* ORACLE */
    function confirmUsdcPrice() internal view override virtual returns (bool) {
        (
            ,
            /* uint80 roundID */ int answer /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/,
            ,
            ,

        ) = AggregatorV3Interface(address(0x16a9FA2FDa030272Ce99B29CF780dFA30361E0f3)).latestRoundData();

        // confirm price of usdc is $1
        return answer >= 99900000;
    }

    /**
     * @notice Returns the address of the ODOS Router contract.
     * @dev This function is used to interact with the ODOS Router for trading and swapping tokens.
     * @return The address of the ODOS Router contract.
     */
    function odosRouter() public override pure returns (address) {
        return 0x0D05a7D3448512B78fa8A9e46c4872C88C4a0D05; // ODOS Router address
    }
}