// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {SuperchainVotingFacet} from "../../../src/facets/account/vote/SuperchainVoting.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";
import {DeploySuperchainVotingFacet} from "../../../script/portfolio_account/facets/DeploySuperchainVoting.s.sol";
import {DeployPortfolioAccountConfig} from "../../../script/portfolio_account/DeployPortfolioAccountConfig.s.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../../src/interfaces/IVoter.sol";
import {IRewardsDistributor} from "../../../src/interfaces/IRewardsDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {SuperchainVotingConfig} from "../../../src/facets/account/config/SuperchainVotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {Setup} from "../utils/Setup.sol";
import {ProtocolTimeLibrary} from "../../../src/libraries/ProtocolTimeLibrary.sol";
import {MockERC20Utils} from "../../utils/MockERC20Utils.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {DeployFacets} from "../../../script/portfolio_account/DeployFacets.s.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {DeployCollateralFacet} from "../../../script/portfolio_account/facets/DeployCollateralFacet.s.sol";
import {MockRootVotingRewardsFactory} from "../../mocks/MockRootVotingRewardsFactory.sol";

contract SuperchainVotingFacetTest is Test, Setup, MockERC20Utils {
    address[] public pools = [address(0x5a7B4970B2610aEe4776A6944d9F2171EE6060B0)];
    uint256[] public weights = [100e18];
    address public launchpadToken = address(0x9126236476eFBA9Ad8aB77855c60eB5BF37586Eb);
    IERC20 public weth = IERC20(0x4200000000000000000000000000000000000006);
    SuperchainVotingConfig public _superchainVotingConfig;
    MockERC20 public mockWeth;
    address public _rootMessageBridge = 0xF278761576f45472bdD721EACA19317cE159c011;
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
        deployer.deploy(address(_portfolioFactory), address(_portfolioAccountConfig), address(_superchainVotingConfig), address(_ve), address(_voter));
        vm.stopPrank();
        
        // Ensure authorized caller is set after deployment (must be done as owner)
        // Note: parent setUp already sets this, but we ensure it's set after facet deployment
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);
        // ensure authorized caller is set
        assertTrue(_portfolioManager.isAuthorizedCaller(_authorizedCaller), "Authorized caller should be set");
        vm.stopPrank();
        
        // Update the voting config reference
        _superchainVotingConfig = SuperchainVotingConfig(address(_superchainVotingConfig));
        
        // Mock WETH and mint to portfolio account
        address wethAddress = address(0x4200000000000000000000000000000000000006);
        mockWeth = deployAndOverwrite(wethAddress, "Wrapped Ether", "WETH", 18);
        
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
        _superchainVotingConfig.setSuperchainPool(pools[0], true, 57073);
        _superchainVotingConfig.setMinimumWethBalance(.0001e18);
        
        // Verify minimum WETH balance is set
        uint256 minimumWethBalance = _superchainVotingConfig.getMinimumWethBalance();
        assertGt(minimumWethBalance, 0, "Minimum WETH balance should be set");
        

        // Now test voting with superchain pool which should fail since user has no WETH
        vm.startPrank(_user);
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(SuperchainVotingFacet.vote.selector, _tokenId, pools, weights);
        // Should revert with MinimumWethBalanceNotMet error, but may fail with CallFailed if setRecipient fails first
        vm.expectRevert();
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();

        // Mint WETH to the portfolio account
        mockWeth.mint(address(_portfolioAccount), minimumWethBalance * 2); // Mint 2x minimum to ensure it passes

        // Verify portfolio account has enough WETH
        uint256 wethBalance = mockWeth.balanceOf(address(_portfolioAccount));
        assertGe(wethBalance, minimumWethBalance, "Portfolio account should have enough WETH");
        
        // Verify the pool is a superchain pool
        bool isSuperchainPool = _superchainVotingConfig.isSuperchainPool(pools[0]);
        assertTrue(isSuperchainPool, "Pool should be marked as superchain pool");
        
        // Now test voting with superchain pool
        vm.startPrank(_user);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
        
        // Verify WETH was approved to RootMessageBridge
        address rootMessageBridge = _rootMessageBridge;
        uint256 allowance = mockWeth.allowance(address(_portfolioAccount), rootMessageBridge);
        assertEq(allowance, wethBalance, "WETH should be approved to RootMessageBridge");
    }

    function testVoteWithSuperchainPoolAndMinimumWethBalance() public {
        uint256 fork = vm.createFork(vm.envString("OP_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(144601822);
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        PortfolioManager _pm = new PortfolioManager(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _pm.deployFactory(bytes32(keccak256(abi.encodePacked("velodrome-usdc"))));
        DeployPortfolioAccountConfig configDeployer = new DeployPortfolioAccountConfig();
        (PortfolioAccountConfig portfolioAccountConfig, VotingConfig votingConfig, LoanConfig loanConfig, ) = configDeployer.deploy();

        address ve = 0xFAf8FD17D9840595845582fCB047DF13f006787d;
        address voter = address(0x41C914ee0c7E1A5edCD0295623e6dC557B5aBf3C);
        
        
        SuperchainVotingConfig superchainVotingConfigImpl = new SuperchainVotingConfig();
        bytes memory initData = abi.encodeWithSelector(VotingConfig.initialize.selector, FORTY_ACRES_DEPLOYER);
        ERC1967Proxy superchainVotingConfigProxy = new ERC1967Proxy(address(superchainVotingConfigImpl), initData);
        SuperchainVotingConfig superchainVotingConfig = SuperchainVotingConfig(address(superchainVotingConfigProxy));
        votingConfig = VotingConfig(address(superchainVotingConfigProxy));
        DeploySuperchainVotingFacet deployer = new DeploySuperchainVotingFacet();
        deployer.deploy(address(portfolioFactory), address(portfolioAccountConfig), address(superchainVotingConfig), address(ve), address(voter));

        // Deploy CollateralFacet which is required for enforceCollateral() call after multicall
        DeployCollateralFacet deployCollateralFacet = new DeployCollateralFacet();
        deployCollateralFacet.deploy(address(portfolioFactory), address(portfolioAccountConfig), address(ve));
        
        // Set loan contract address which is required for enforceCollateral() to call getMaxLoan()
        // Use Optimism loan contract address (not Base)
        address loanContract = address(0xf132bD888897254521D13e2c401e109caABa06A7);
        portfolioAccountConfig.setLoanContract(loanContract);
        // Mark loan contract as persistent for fork testing
        vm.makePersistent(loanContract);
        
        superchainVotingConfig.setSuperchainPool(address(0x894d6Ea97767EbeCEfE01c9410f6Bd67935AA952), true, 57073);
        superchainVotingConfig.setMinimumWethBalance(.001e18);

        vm.stopPrank();
        uint256 tokenId = 5005;
        
        address user = IVotingEscrow(ve).ownerOf(tokenId);
        vm.startPrank(user, user);
        address portfolioAccount = portfolioFactory.createAccount(user);
        IVotingEscrow(ve).transferFrom(user, portfolioAccount, tokenId);
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        uint256 preWethBalance = mockWeth.balanceOf(portfolioAccount);

        // vote on superchain pool  0x894d6Ea97767EbeCEfE01c9410f6Bd67935AA952
        address[] memory votePools = new address[](1);
        votePools[0] = address(0x894d6Ea97767EbeCEfE01c9410f6Bd67935AA952);
        uint256[] memory voteWeights = new uint256[](1);
        voteWeights[0] = 100e18;
        
        // Call vote through PortfolioManager multicall (required by onlyPortfolioManagerMulticall modifier)
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(SuperchainVotingFacet.vote.selector, tokenId, votePools, voteWeights);
        
        // should revert since user has no WETH
        vm.expectRevert();
        _pm.multicall(calldatas, portfolioFactories);
        
        // transferWeth to portfolio Account
        IERC20(0x4200000000000000000000000000000000000006).transfer(portfolioAccount, .002e18);
        _pm.multicall(calldatas, portfolioFactories);

        uint256 lastVoted = IVoter(address(voter)).lastVoted(tokenId);
        assertEq(lastVoted, block.timestamp);

        // verify WETH was approved to RootMessageBridge
        address rootMessageBridge = _rootMessageBridge;
        uint256 allowance = mockWeth.allowance(address(portfolioAccount), rootMessageBridge);
        assertEq(allowance, .002e18, "WETH should be approved to RootMessageBridge");

        uint256 postWethBalance = mockWeth.balanceOf(portfolioAccount);
        assertEq(postWethBalance, preWethBalance + .002e18, "WETH should be transferred to portfolio account");


    }
}

