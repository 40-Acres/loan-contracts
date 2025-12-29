pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";
import {DeployFacets} from "../../../script/portfolio_account/DeployFacets.s.sol";
import {DeployPortfolioAccountConfig} from "../../../script/portfolio_account/DeployPortfolioAccountConfig.s.sol";
import {PortfolioFactoryDeploy} from "../../../script/portfolio_account/PortfolioFactoryDeploy.s.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../../src/interfaces/IVoter.sol";
import {IRewardsDistributor} from "../../../src/interfaces/IRewardsDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {Setup} from "../utils/Setup.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";

contract VotingFacetTest is Test, Setup {
    address[] public pools = [address(0x5a7B4970B2610aEe4776A6944d9F2171EE6060B0)];
    uint256[] public weights = [100e18];
    address public launchpadToken = address(0x9126236476eFBA9Ad8aB77855c60eB5BF37586Eb);


    function testInvalidSender() public {
        vm.expectRevert();
        VotingFacet(_portfolioAccount).vote(_tokenId, pools, weights);
    }

    function testVoteEmptyPools() public {
        vm.startPrank(_user);
        vm.expectRevert();
        // multicall from portfolio manager
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(VotingFacet.vote.selector, _tokenId, new address[](0), new uint256[](0));
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testVoteInvalidPool() public {
        vm.startPrank(_user);
        vm.expectRevert();
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(VotingFacet.vote.selector, _tokenId, pools, weights);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testVote() public {
        vm.startPrank(_owner);
        _votingConfig.setApprovedPool(pools[0], true);
        vm.stopPrank();
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(VotingFacet.vote.selector, _tokenId, pools, weights);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testVoteForLaunchpadToken() public {
        vm.startPrank(_owner);
        _votingConfig.setLaunchpadPoolTokenForNextEpoch(pools[0], launchpadToken);
        vm.stopPrank();
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(VotingFacet.voteForLaunchpadToken.selector, _tokenId, pools, weights, true);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testVoteEnterManualVotingMode() public {
        // token entered this week, user should be able to switch to manual voting even if not voted yet
        vm.startPrank(_owner);
        _votingConfig.setApprovedPool(pools[0], true);
        vm.stopPrank();

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(VotingFacet.setVotingMode.selector, _tokenId, true);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        vm.startPrank(_user);
        // user should not be able to switch to manual mode
        vm.expectRevert();
        _portfolioManager.multicall(calldatas, portfolioFactories);

        bool isManualVoting = VotingFacet(_portfolioAccount).isManualVoting(_tokenId);
        assertFalse(isManualVoting, "User should be in automatic mode after switching");
        // let user vote for pool and skip to next epoch
        calldatas[0] = abi.encodeWithSelector(VotingFacet.vote.selector, _tokenId, pools, weights);
        // week 0: user voted, but not eligible for manual voting, manual votes before voting window
        _portfolioManager.multicall(calldatas, portfolioFactories);
        isManualVoting = VotingFacet(_portfolioAccount).isManualVoting(_tokenId);
        assertTrue(isManualVoting, "User should be in manual mode after voting");
 
        uint256 currentTimestamp = block.timestamp + 7 days;
        vm.warp(currentTimestamp);
        vm.roll(block.number + 1);
        // week 1: user voted last week, should be eligible for manual voting

        isManualVoting = VotingFacet(_portfolioAccount).isManualVoting(_tokenId);
        assertTrue(isManualVoting, "User should be in manual mode after voting last week");
        // user is already in manual mode, but let's verify they can switch back to automatic
        calldatas[0] = abi.encodeWithSelector(VotingFacet.setVotingMode.selector, _tokenId, false);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        isManualVoting = VotingFacet(_portfolioAccount).isManualVoting(_tokenId);
        assertFalse(isManualVoting, "User should be in automatic mode after switching");
        // switch back to manual mode
        calldatas[0] = abi.encodeWithSelector(VotingFacet.setVotingMode.selector, _tokenId, true);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
        isManualVoting = VotingFacet(_portfolioAccount).isManualVoting(_tokenId);
        assertTrue(isManualVoting, "User should be in manual mode");


        currentTimestamp = currentTimestamp + 7 days;
        vm.warp(currentTimestamp);
        vm.roll(block.number + 1);
        // week 2: user missed voting last week, should be in automatic mode
        
       // user should be in automatic mode since they missed voting last epoch
        isManualVoting = VotingFacet(_portfolioAccount).isManualVoting(_tokenId);
        assertFalse(isManualVoting, "User should be in automatic mode since missed voting last epoch");

        // user should not be able to switch to manual mode
        calldatas[0] = abi.encodeWithSelector(VotingFacet.setVotingMode.selector, _tokenId, true);
        vm.expectRevert();
        _portfolioManager.multicall(calldatas, portfolioFactories);
        isManualVoting = VotingFacet(_portfolioAccount).isManualVoting(_tokenId);
        assertFalse(isManualVoting, "User should be in automatic mode since missed voting last epoch");
    }


    function testDefaultVote() public {
        vm.startPrank(_owner);
        _votingConfig.setApprovedPool(pools[0], true);
        vm.stopPrank();
        vm.startPrank(_authorizedCaller);
        vm.expectRevert();
        VotingFacet(_portfolioAccount).defaultVote(_tokenId, pools, weights);

        vm.warp(ProtocolTimeLibrary.epochVoteEnd(block.timestamp) - 1 hours);
        VotingFacet(_portfolioAccount).defaultVote(_tokenId, pools, weights);
        vm.stopPrank();

        uint256 lastVoted = IVoter(address(_voter)).lastVoted(_tokenId);
        assertEq(lastVoted, block.timestamp);
    }
}