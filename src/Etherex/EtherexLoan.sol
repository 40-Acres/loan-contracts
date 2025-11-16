// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {IXVoter} from "../interfaces/IXVoter.sol";
import {IRewardsDistributor} from "../interfaces/IRewardsDistributor.sol";
import {ICLGauge} from "../interfaces/ICLGauge.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {RateStorage} from "../RateStorage.sol";
import {LoanStorage} from "../LoanStorage.sol";
import {ISwapper} from "../interfaces/ISwapper.sol";
import {LoanUtils} from "../LoanUtils.sol";
import { IMarketViewFacet } from "../interfaces/IMarketViewFacet.sol";
import {IFlashLoanProvider} from "../interfaces/IFlashLoanProvider.sol";
import {IFlashLoanReceiver} from "../interfaces/IFlashLoanReceiver.sol";
import { PortfolioFactory } from "../accounts/PortfolioFactory.sol";
import {IVoteModule} from "../interfaces/IVoteModule.sol";
import {IXRex} from "../interfaces/IXRex.sol";
import {IXRexFacet} from "../interfaces/IXRexFacet.sol";
import {IUSDC} from "../interfaces/IUSDC.sol";
import {IXLoan} from "../interfaces/IXLoan.sol";
import {XPharaohLoan} from "../Pharaoh/XPharaohLoan.sol";

contract EtherexLoan is XPharaohLoan {
    function initialize(address vault, address asset) initializer public override {
        __Ownable_init(msg.sender); 
        __UUPSUpgradeable_init();
        address[] memory pools = new address[](1);
        pools[0] = 0x5Dc74003C0a9D08EB750B10ed5b02fA7D58d4d1e;
        _defaultPools = pools;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;
        _defaultWeights = amounts;
        _vault = vault;
        _voter = IXVoter(0x942117Ec0458a8AA08669E94B52001Bd43F889C1); // Linea voter 
        _vaultAsset = IERC20(asset);
        _liquidAsset = IERC20(0xe4eEB461Ad1e4ef8b8EF71a33694CCD84Af051C4); // rex33
        _lockedAsset = IERC20(0xc93B315971A4f260875103F5DA84cB1E30f366Cc);
        _multiplier = 12;
        _voteModule = IVoteModule(0xedD7cbc9C47547D0b552d5Bc2BE76135f49C15b1);
    }


    /**
     * @notice Processes the rewards for the loan
     * @dev Processes the rewards for the loan
     * @param fees The fees to be claimed
     * @param tokens The tokens to be swapped
     * @param tradeData The trade data
     */
    function _processRewards(address[] calldata fees, address[][] calldata tokens, bytes calldata tradeData) internal override {
        IXRexFacet(address(msg.sender)).xRexProcessRewards(fees, tokens, tradeData);
    }

    /** ORACLE */
    
    /**
     * @notice Confirms the price of USDC is $1 and if is not in the blacklist.
     * @dev This function checks the latest round data from the Chainlink price feed for USDC.
     * @return bool indicating whether the price of USDC is greater than or equal to $0.999.
     */
    function confirmUsdcLoan(address portfolioAccount) override internal view returns (bool) {
        address user = PortfolioFactory(getPortfolioFactory()).ownerOf(portfolioAccount);
        bool isBlacklisted = IUSDC(address(_vaultAsset)).isBlacklisted(user);
        if(isBlacklisted) {
            return false;
        }

        (
            /* uint80 roundID */,
            int answer ,
            /*uint startedAt*/,
            uint256 timestamp,
            /*uint80 answeredInRound*/

        ) = AggregatorV3Interface(address(0xAADAa473C1bDF7317ec07c915680Af29DeBfdCb5)).latestRoundData();

        // add staleness check, data updates every 24 hours
        require(timestamp > block.timestamp - 25 hours);
        // confirm price of usdc is $1
        return answer <= 100100000;
    }

    function _entryPoint() internal view override returns (address) {
        return 0x40AC2E93d1257196a418fcE7D6eDAcDE65aAf2BA;
    }
    
}
