// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "./interfaces/IVoter.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IVoter} from "./interfaces/IVoter.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IAerodromeRouter} from "./interfaces/IAerodromeRouter.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";
import { IRouter } from "./interfaces/IRouter.sol";
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