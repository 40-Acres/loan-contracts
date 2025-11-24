// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// import {INonfungiblePositionManager} from "contracts/periphery/interfaces/INonfungiblePositionManager.sol";
// import {IVoter} from "contracts/core/interfaces/IVoter.sol";
// import {ICLPool} from "contracts/core/interfaces/ICLPool.sol";
// import {ICLGaugeFactory} from "contracts/gauge/interfaces/ICLGaugeFactory.sol";

interface IXGauge {
    function rewardsList() external view returns (address[] memory _rewards);
}