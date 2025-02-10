// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.27;

import "./interfaces/IVoter.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IVoter} from "./interfaces/IVoter.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IAerodromeRouter} from "./interfaces/IAerodromeRouter.sol";
import {IRewardsDistributor} from "./interfaces/IRewardsDistributor.sol";
import {Loan } from "./Loan.sol";

contract VeloLoan is Loan {
    function initialize(address vault) initializer public virtual override {
        __Ownable_init(msg.sender); //set owner to msg.sender
        __UUPSUpgradeable_init();
        address[] memory pools = new address[](1);
        pools[0] = 0xa0A215dE234276CAc1b844fD58901351a50fec8A;
        _defaultPools = pools;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;
        _defaultWeights = amounts;

        _defaultPoolChangeTime = block.timestamp;
        _vault = vault;
        _voter = IVoter(0x41C914ee0c7E1A5edCD0295623e6dC557B5aBf3C);
        _rewardsDistributor = IRewardsDistributor(0x9D4736EC60715e71aFe72973f7885DCBC21EA99b);
        _usdc = IERC20(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85);
        _aero = IERC20(0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db);
        _ve = IVotingEscrow(0xFAf8FD17D9840595845582fCB047DF13f006787d);
        _aeroRouter = IAerodromeRouter(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858);
        _aeroFactory = address(0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a);
        _multiplier = 8;
    }

    

    function canVoteOnPool(uint256 tokenId) internal override view returns (bool) {
        return _ve.voted(tokenId) == false; // TODO FIX
    }
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