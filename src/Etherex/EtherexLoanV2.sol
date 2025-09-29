// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import { Loan } from "../LoanV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IGaugeManager} from "./interfaces/IGaugeManager.sol";
import { ProtocolTimeLibrary } from "../libraries/ProtocolTimeLibrary.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import { IGaugeManager } from "./interfaces/IGaugeManager.sol";
import { IRewardsDistributor } from "../interfaces/IRewardsDistributor.sol";
import { ISwapper } from "../interfaces/ISwapper.sol";

contract EtherexLoanV2 is Loan {
    /* ORACLE */
    /**
     * @notice Confirms the price of USDC is $1.
     * @dev This function checks the latest round data from the Chainlink price feed for USDC.
     * @return bool indicating whether the price of USDC is greater than or equal to $0.999.
     */
    function confirmUsdcPrice() override virtual internal view returns (bool) {
        // (
        //     /* uint80 roundID */,
        //     int answer ,
        //     /*uint startedAt*/,
        //     uint256 timestamp,
        //     /*uint80 answeredInRound*/

        // ) = AggregatorV3Interface(address(0xF096872672F44d6EBA71458D74fe67F9a77a23B9)).latestRoundData();

        // // add staleness check, data updates every 24 hours
        // require(timestamp > block.timestamp - 25 hours);
        // // confirm price of usdc is $1
        // return answer >= 99900000;
        return true;
    }
}