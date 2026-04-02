// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {SuperchainVotingFacet} from "../../../../src/facets/account/vote/SuperchainVoting.sol";
import {VotingFacet} from "../../../../src/facets/account/vote/VotingFacet.sol";
import {DeploySuperchainVotingFacet} from "../../../../script/portfolio_account/facets/DeploySuperchainVoting.s.sol";
import {DeployPortfolioFactoryConfig} from "../../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../../../src/interfaces/IVoter.sol";
import {IRewardsDistributor} from "../../../../src/interfaces/IRewardsDistributor.sol";
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {SuperchainVotingConfig} from "../../../../src/facets/account/config/SuperchainVotingConfig.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {Setup} from "../utils/Setup.sol";
import {ProtocolTimeLibrary} from "../../../../src/libraries/ProtocolTimeLibrary.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {DeployFacets} from "../../../../script/portfolio_account/DeployFacets.s.sol";
import {CollateralFacet} from "../../../../src/facets/account/collateral/CollateralFacet.sol";
import {DeployCollateralFacet} from "../../../../script/portfolio_account/facets/DeployCollateralFacet.s.sol";
import {MockRootVotingRewardsFactory} from "../../../mocks/MockRootVotingRewardsFactory.sol";

interface IOwnable {
    function owner() external view returns (address);
}

import {Loan as LoanV2} from "../../../../src/LoanV2.sol";
contract SuperchainVotingFacetTest is Test, Setup {
    address[] public pools = [address(0x5a7B4970B2610aEe4776A6944d9F2171EE6060B0)];
    uint256[] public weights = [100e18];
    address public launchpadToken = address(0x9126236476eFBA9Ad8aB77855c60eB5BF37586Eb);
    SuperchainVotingConfig public _superchainVotingConfig;
    function setUp() public override {
        // Call parent setUp to get basic setup
        super.setUp();

        // Remove VotingFacet and deploy SuperchainVotingFacet
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        // Find VotingFacet by checking for its vote selector
        bytes4 voteSelector = VotingFacet.vote.selector;
        address oldVotingFacet = _facetRegistry.getFacetForSelector(voteSelector);
        if (oldVotingFacet != address(0)) {
            // Verify it's actually VotingFacet by checking its name
            string memory facetName = _facetRegistry.getFacetName(oldVotingFacet);
            if (keccak256(bytes(facetName)) == keccak256(bytes("VotingFacet"))) {
                // Remove the old VotingFacet before registering SuperchainVotingFacet
                _facetRegistry.removeFacet(oldVotingFacet);
            }
        }

        SuperchainVotingConfig superchainVotingConfigImpl = new SuperchainVotingConfig();
        bytes memory initData = abi.encodeWithSelector(VotingConfig.initialize.selector, FORTY_ACRES_DEPLOYER);
        ERC1967Proxy superchainVotingConfigProxy = new ERC1967Proxy(address(superchainVotingConfigImpl), initData);
        _superchainVotingConfig = SuperchainVotingConfig(address(superchainVotingConfigProxy));

        // Deploy and register SuperchainVotingFacet
        DeploySuperchainVotingFacet deployer = new DeploySuperchainVotingFacet();
        deployer.deploy(address(_portfolioFactory), address(_superchainVotingConfig), address(_ve), address(_voter));
        vm.stopPrank();

        // Ensure authorized caller is set after deployment (must be done as owner)
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);
        assertTrue(_portfolioManager.isAuthorizedCaller(_authorizedCaller), "Authorized caller should be set");
        vm.stopPrank();

        // Deploy and overwrite ROOT_VOTING_REWARDS_FACTORY with mock
        address rootVotingRewardsFactoryAddress = address(0x7dc9fd82f91B36F416A89f5478375e4a79f4Fb2F);
        MockRootVotingRewardsFactory mockFactory = new MockRootVotingRewardsFactory();
        vm.etch(rootVotingRewardsFactoryAddress, address(mockFactory).code);
    }

    function testInvalidSender() public {
        vm.expectRevert();
        SuperchainVotingFacet(_portfolioAccount).vote(_tokenId, pools, weights);
    }

    function testVoteEmptyPools() public {
        vm.startPrank(_user);
        vm.expectRevert();
        // multicall from portfolio manager
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(SuperchainVotingFacet.vote.selector, _tokenId, new address[](0), new uint256[](0));
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testVoteInvalidPool() public {
        vm.startPrank(_user);
        vm.expectRevert();
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(SuperchainVotingFacet.vote.selector, _tokenId, pools, weights);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testVote() public {
        vm.startPrank(_owner);
        _superchainVotingConfig.setApprovedPool(pools[0], true);
        vm.stopPrank();
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(SuperchainVotingFacet.vote.selector, _tokenId, pools, weights);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testVoteForLaunchpadToken() public {
        vm.startPrank(_owner);
        _superchainVotingConfig.setLaunchpadPoolTokenForNextEpoch(pools[0], launchpadToken);
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
        _superchainVotingConfig.setApprovedPool(pools[0], true);
        vm.stopPrank();

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(VotingFacet.setVotingMode.selector, _tokenId, true);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        vm.startPrank(_user);
        // user should not be able to switch to manual mode
        vm.expectRevert();
        _portfolioManager.multicall(calldatas, portfolioFactories);

        bool isManualVoting = SuperchainVotingFacet(_portfolioAccount).isManualVoting(_tokenId);
        assertFalse(isManualVoting, "User should be in automatic mode after switching");
        // let user vote for pool and skip to next epoch
        calldatas[0] = abi.encodeWithSelector(VotingFacet.vote.selector, _tokenId, pools, weights);
        // week 0: user voted, but not eligible for manual voting, manual votes before voting window
        _portfolioManager.multicall(calldatas, portfolioFactories);
        isManualVoting = SuperchainVotingFacet(_portfolioAccount).isManualVoting(_tokenId);
        assertTrue(isManualVoting, "User should be in manual mode after voting");
 
        uint256 currentTimestamp = block.timestamp + 7 days;
        vm.warp(currentTimestamp);
        vm.roll(block.number + 1);
        // week 1: user voted last week, should be eligible for manual voting

        isManualVoting = SuperchainVotingFacet(_portfolioAccount).isManualVoting(_tokenId);
        assertTrue(isManualVoting, "User should be in manual mode after voting last week");
        // user is already in manual mode, but let's verify they can switch back to automatic
        calldatas[0] = abi.encodeWithSelector(VotingFacet.setVotingMode.selector, _tokenId, false);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        isManualVoting = SuperchainVotingFacet(_portfolioAccount).isManualVoting(_tokenId);
        assertFalse(isManualVoting, "User should be in automatic mode after switching");
        // switch back to manual mode
        calldatas[0] = abi.encodeWithSelector(VotingFacet.setVotingMode.selector, _tokenId, true);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
        isManualVoting = SuperchainVotingFacet(_portfolioAccount).isManualVoting(_tokenId);
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
        _superchainVotingConfig.setApprovedPool(pools[0], true);
        vm.stopPrank();
        vm.startPrank(_authorizedCaller);
        vm.expectRevert();
        SuperchainVotingFacet(_portfolioAccount).defaultVote(_tokenId, pools, weights);

        vm.warp(ProtocolTimeLibrary.epochVoteEnd(block.timestamp) - 1 hours);
        SuperchainVotingFacet(_portfolioAccount).defaultVote(_tokenId, pools, weights);
        vm.stopPrank();

        uint256 lastVoted = IVoter(address(_voter)).lastVoted(_tokenId);
        assertEq(lastVoted, block.timestamp);
    }

    function testVoteWithSuperchainPool() public {
        // Mark the pool as a superchain pool
        vm.startPrank(_owner);
        _superchainVotingConfig.setApprovedPool(pools[0], true);
        _superchainVotingConfig.setSuperchainPool(pools[0], true);

        // Get the veNFT's locked balance
        int128 lockedAmount = _ve.locked(_tokenId).amount;
        uint256 lockedBalance = uint256(uint128(lockedAmount));
        assertGt(lockedBalance, 0, "veNFT should have locked balance");

        // Set minimum per pool higher than locked balance — vote should fail
        _superchainVotingConfig.setMinimumLockedBalancePerPool(lockedBalance + 1);
        vm.stopPrank();

        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(SuperchainVotingFacet.vote.selector, _tokenId, pools, weights);
        // Should revert with InsufficientLockedBalance
        vm.expectRevert();
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();

        // Set minimum per pool lower than locked balance — vote should succeed
        vm.prank(_owner);
        _superchainVotingConfig.setMinimumLockedBalancePerPool(lockedBalance / 2);

        // Verify the pool is a superchain pool
        assertTrue(_superchainVotingConfig.isSuperchainPool(pools[0]), "Pool should be marked as superchain pool");

        // Now test voting with superchain pool — should succeed
        vm.startPrank(_user);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testVoteWithSuperchainPoolOnFork() public {
        uint256 fork = vm.createFork(vm.envString("OP_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(144601822);

        // Deploy and overwrite ROOT_VOTING_REWARDS_FACTORY with mock
        MockRootVotingRewardsFactory mockFactory = new MockRootVotingRewardsFactory();
        vm.etch(address(0x7dc9fd82f91B36F416A89f5478375e4a79f4Fb2F), address(mockFactory).code);

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        PortfolioManager _pm = new PortfolioManager(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _pm.deployFactory(bytes32(keccak256(abi.encodePacked("velodrome-usdc"))));
        DeployPortfolioFactoryConfig configDeployer = new DeployPortfolioFactoryConfig();
        (PortfolioFactoryConfig portfolioFactoryConfig, VotingConfig votingConfig, LoanConfig loanConfig, ) = configDeployer.deploy(address(portfolioFactory));

        address ve = 0xFAf8FD17D9840595845582fCB047DF13f006787d;
        address voter = address(0x41C914ee0c7E1A5edCD0295623e6dC557B5aBf3C);

        SuperchainVotingConfig superchainVotingConfigImpl = new SuperchainVotingConfig();
        bytes memory initData = abi.encodeWithSelector(VotingConfig.initialize.selector, FORTY_ACRES_DEPLOYER);
        ERC1967Proxy superchainVotingConfigProxy = new ERC1967Proxy(address(superchainVotingConfigImpl), initData);
        SuperchainVotingConfig superchainVotingConfig = SuperchainVotingConfig(address(superchainVotingConfigProxy));
        votingConfig = VotingConfig(address(superchainVotingConfigProxy));
        DeploySuperchainVotingFacet deployer = new DeploySuperchainVotingFacet();
        deployer.deploy(address(portfolioFactory), address(superchainVotingConfig), address(ve), address(voter));

        // Deploy CollateralFacet which is required for enforceCollateral() call after multicall
        DeployCollateralFacet deployCollateralFacet = new DeployCollateralFacet();
        deployCollateralFacet.deploy(address(portfolioFactory), address(ve));

        // Set loan contract address which is required for enforceCollateral() to call getMaxLoan()
        address loanContract = address(0xf132bD888897254521D13e2c401e109caABa06A7);
        vm.makePersistent(loanContract);

        vm.stopPrank();

        // Upgrade loan contract to LoanV2 first (needed for getPortfolioFactory)
        LoanV2 loanV2 = new LoanV2();
        vm.prank(IOwnable(loanContract).owner());
        LoanV2(loanContract).upgradeToAndCall(address(loanV2), new bytes(0));

        // Set portfolio factory on loan contract, then link config
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));
        vm.stopPrank();

        vm.prank(IOwnable(loanContract).owner());
        LoanV2(loanContract).setPortfolioFactory(address(portfolioFactory));

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        portfolioFactoryConfig.setLoanContract(loanContract);

        superchainVotingConfig.setSuperchainPool(address(0x894d6Ea97767EbeCEfE01c9410f6Bd67935AA952), true);

        uint256 tokenId = 5005;

        // Get locked balance for this token and set minimum accordingly
        int128 lockedAmount = IVotingEscrow(ve).locked(tokenId).amount;
        uint256 lockedBalance = uint256(uint128(lockedAmount));
        assertGt(lockedBalance, 0, "veNFT should have locked balance");

        // Set minimum higher than locked balance — should fail
        superchainVotingConfig.setMinimumLockedBalancePerPool(lockedBalance + 1);
        vm.stopPrank();

        address user = IVotingEscrow(ve).ownerOf(tokenId);
        vm.startPrank(user, user);
        address portfolioAccount = portfolioFactory.createAccount(user);
        IVotingEscrow(ve).transferFrom(user, portfolioAccount, tokenId);
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // vote on superchain pool
        address[] memory votePools = new address[](1);
        votePools[0] = address(0x894d6Ea97767EbeCEfE01c9410f6Bd67935AA952);
        uint256[] memory voteWeights = new uint256[](1);
        voteWeights[0] = 100e18;

        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(SuperchainVotingFacet.vote.selector, tokenId, votePools, voteWeights);

        // Should revert — locked balance < minimum per pool
        vm.expectRevert();
        _pm.multicall(calldatas, portfolioFactories);
        vm.stopPrank();

        // Lower minimum to allow voting
        vm.prank(FORTY_ACRES_DEPLOYER);
        superchainVotingConfig.setMinimumLockedBalancePerPool(lockedBalance / 2);

        vm.startPrank(user, user);
        _pm.multicall(calldatas, portfolioFactories);

        uint256 lastVoted = IVoter(address(voter)).lastVoted(tokenId);
        assertEq(lastVoted, block.timestamp);
        vm.stopPrank();
    }
}

