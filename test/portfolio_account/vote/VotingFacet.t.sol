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
        vm.expectRevert(VotingFacet.PoolsCannotBeEmpty.selector);
        VotingFacet(_portfolioAccount).vote(_tokenId, new address[](0), new uint256[](0));
        vm.stopPrank();
    }

    function testVoteInvalidPool() public {
        vm.startPrank(_user);
        vm.expectRevert();
        VotingFacet(_portfolioAccount).vote(_tokenId, pools, weights);
        vm.stopPrank();
    }

    function testVote() public {
        vm.startPrank(_owner);
        _votingConfig.setApprovedPool(pools[0], true);
        vm.stopPrank();
        vm.startPrank(_user);
        VotingFacet(_portfolioAccount).vote(_tokenId, pools, weights);
        vm.stopPrank();
    }

    function testVoteForLaunchpadToken() public {
        vm.startPrank(_owner);
        _votingConfig.setLaunchpadPoolTokenForNextEpoch(pools[0], launchpadToken);
        vm.stopPrank();
        vm.startPrank(_user);
        VotingFacet(_portfolioAccount).voteForLaunchpadToken(_tokenId, pools, weights, true);
        vm.stopPrank();
    }
}