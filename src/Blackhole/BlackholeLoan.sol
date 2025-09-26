// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "../interfaces/IVoter.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {IAerodromeRouter} from "../interfaces/IAerodromeRouter.sol";
import {IRewardsDistributor} from "../interfaces/IRewardsDistributor.sol";
import { IRouter } from "../interfaces/IRouter.sol";
import {Loan } from "../Loan.sol";

contract BlackholeLoan is Loan {
    function initialize(address vault, address asset) initializer public virtual override {
        __Ownable_init(msg.sender); 
        __UUPSUpgradeable_init();
        address[] memory pools = new address[](1);
        pools[0] = 0x4A930a63B13e6683a204Cb10Ef20F68310231459;
        _defaultPools = pools;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;
        _defaultWeights = amounts;
        _defaultPoolChangeTime = block.timestamp;
        _vault = vault;
        _voter = IVoter(0xE30D0C8532721551a51a9FeC7FB233759964d9e3); // 
        _rewardsDistributor = IRewardsDistributor(0x88a49cFCee0Ed5B176073DDE12186C4c922A9cD0);
        _asset = IERC20(asset);
        _aero = IERC20(0xcd94a87696FAC69Edae3a70fE5725307Ae1c43f6);
        _ve = IVotingEscrow(0xEac562811cc6abDbB2c9EE88719eCA4eE79Ad763);
        _aeroRouter = IAerodromeRouter(0x0000000000000000000000000000000000000000);
        _aeroFactory = address(0xfE926062Fb99CA5653080d6C14fE945Ad68c265C);
        _multiplier = 12;
    }
}
