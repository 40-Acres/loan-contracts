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

contract EtherexLoan is Loan {
    function initialize(address vault, address asset) initializer public virtual override {
        __Ownable_init(msg.sender); 
        __UUPSUpgradeable_init();
        address[] memory pools = new address[](1);
        pools[0] = 0x5Dc74003C0a9D08EB750B10ed5b02fA7D58d4d1e;
        _defaultPools = pools;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;
        _defaultWeights = amounts;
        _defaultPoolChangeTime = block.timestamp;
        _vault = vault;
        _voter = IVoter(0x942117Ec0458a8AA08669E94B52001Bd43F889C1); // Linea voter 
        _rewardsDistributor = IRewardsDistributor(0x88a49cFCee0Ed5B176073DDE12186C4c922A9cD0);
        _asset = IERC20(asset);
        _aero = IERC20(0xEfD81eeC32B9A8222D1842ec3d99c7532C31e348);
        _ve = IVotingEscrow(0xc93B315971A4f260875103F5DA84cB1E30f366Cc);
        _aeroRouter = IAerodromeRouter(0x85974429677c2a701af470B82F3118e74307826e);
        _aeroFactory = address(0xAe334f70A7FC44FCC2df9e6A37BC032497Cf80f1);
        _multiplier = 12;
    }
}
