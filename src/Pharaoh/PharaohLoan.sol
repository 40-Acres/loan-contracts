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

contract PharaohLoan is Loan {
    function initialize(address vault, address asset) initializer public virtual override {
        __Ownable_init(msg.sender); //set owner to msg.sender
        __UUPSUpgradeable_init();
        address[] memory pools = new address[](1);
        pools[0] = 0x1a2950978E29C5e590C77B0b6247beDbFB0b4185;
        _defaultPools = pools;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;
        _defaultWeights = amounts;

        _defaultPoolChangeTime = block.timestamp;
        _vault = vault;
        _voter = IVoter(0xAAAf3D9CDD3602d117c67D80eEC37a160C8d9869);
        _rewardsDistributor = IRewardsDistributor(0xAAA9Ea898ae0b7D3805aF555AF3a2e3BdF06D22C);
        _usdc = IERC20(asset);
        _aero = IERC20(0xAAAB9D12A30504559b0C5a9A5977fEE4A6081c6b);
        _ve = IVotingEscrow(0xAAAEa1fB9f3DE3F70E89f37B69Ab11B47eb9Ce6F);
        _aeroRouter = IAerodromeRouter(0xAAA45c8F5ef92a000a121d102F4e89278a711Faa);
        _aeroFactory = address(0xAAA32926fcE6bE95ea2c51cB4Fcb60836D320C42);
        _multiplier = 12;
    }

}