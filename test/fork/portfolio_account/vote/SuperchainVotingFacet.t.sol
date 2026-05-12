// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/**
 * @title SuperchainVotingFacetTest
 * @dev Tests for SuperchainVotingFacet after the migration from per-pool
 *      allowlist (SuperchainVotingConfig.setSuperchainPool) to factory
 *      allowlist (RootPoolVotingConfig.setRootPoolFactory).
 *
 *      The facet now identifies superchain pools at runtime by probing
 *      IRootPool(pool).factory() and checking the returned address against
 *      a small allowlist of root-pool factories. A second-stage chainid()
 *      probe must succeed and return a non-zero, non-local chain id before
 *      the facet calls setRecipient on the RootVotingRewardsFactory or
 *      enforces the minimum-locked-balance per pool.
 */

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {SuperchainVotingFacet} from "../../../../src/facets/account/vote/SuperchainVoting.sol";
import {VotingFacet} from "../../../../src/facets/account/vote/VotingFacet.sol";
import {DeploySuperchainVotingFacet} from "../../../../script/portfolio_account/facets/DeploySuperchainVoting.s.sol";
import {DeployPortfolioFactoryConfig} from "../../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../../../src/interfaces/IVoter.sol";
import {IRewardsDistributor} from "../../../../src/interfaces/IRewardsDistributor.sol";
import {IRootPool} from "../../../../src/interfaces/IRootPool.sol";
import {IRootVotingRewardsFactory} from "../../../../src/interfaces/IRootVotingRewardsFactory.sol";
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {RootPoolVotingConfig} from "../../../../src/facets/account/config/RootPoolVotingConfig.sol";
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
import {MockRootPool} from "../../../mocks/MockRootPool.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

interface IOwnable {
    function owner() external view returns (address);
}

import {Loan as LoanV2} from "../../../../src/LoanV2.sol";

/**
 * @dev Helper contract that ALWAYS reverts on factory() but returns a
 *      configurable chainid(). Used to test the stage-1 try/catch.
 */
contract RevertingFactoryPool {
    uint256 private immutable _chainid;
    constructor(uint256 chainid_) { _chainid = chainid_; }
    function chainid() external view returns (uint256) { return _chainid; }
    function factory() external pure returns (address) { revert("no factory"); }
}

/**
 * @dev Helper contract that returns an allowlisted factory but ALWAYS
 *      reverts on chainid(). Used to test the stage-2 try/catch.
 */
contract RevertingChainidPool {
    address private immutable _factory;
    constructor(address factory_) { _factory = factory_; }
    function factory() external view returns (address) { return _factory; }
    function chainid() external pure returns (uint256) { revert("no chainid"); }
}

/**
 * @dev Helper contract with NO factory() and NO chainid() — pure EOA-like
 *      placeholder. Used to test stage-1 skip when the call returndatasize
 *      is zero (try/catch swallows it).
 */
contract EmptyPool { }

contract SuperchainVotingFacetTest is Test, Setup {
    // Real Aerodrome pool address; used in tests where we expect an
    // approval failure or a non-superchain skip.
    address[] public pools = [address(0x5a7B4970B2610aEe4776A6944d9F2171EE6060B0)];
    uint256[] public weights = [100e18];
    address public launchpadToken = address(0x9126236476eFBA9Ad8aB77855c60eB5BF37586Eb);
    RootPoolVotingConfig public _superchainVotingConfig;

    // OP mainnet Velodrome V2 RootPoolFactory address (one of two — see
    // user instructions). Used to register the factory for fork tests.
    address constant OP_V2_ROOT_POOL_FACTORY = 0x31832f2a97Fd20664D76Cc421207669b55CE4BC0;
    address constant ROOT_VOTING_REWARDS_FACTORY = 0x7dc9fd82f91B36F416A89f5478375e4a79f4Fb2F;

    // Local fixture: deterministic mock factory address; never makes
    // an external call — just used as the value returned by factory().
    address constant MOCK_FACTORY = 0xF7c70adA1234567890abcdeF1234567890aBCDEf;
    address constant OTHER_FACTORY = 0xbAaAaad1234567890ABcdeF1234567890AbCdef1;

    // Foreign chain id used in mocks (Soneium).
    uint256 constant FOREIGN_CHAIN = 1868;

    function setUp() public override {
        // Call parent setUp to get basic Base fork setup
        super.setUp();

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        // Remove the default VotingFacet so we can register SuperchainVotingFacet
        bytes4 voteSelector = VotingFacet.vote.selector;
        address oldVotingFacet = _facetRegistry.getFacetForSelector(voteSelector);
        if (oldVotingFacet != address(0)) {
            string memory facetName = _facetRegistry.getFacetName(oldVotingFacet);
            if (keccak256(bytes(facetName)) == keccak256(bytes("VotingFacet"))) {
                _facetRegistry.removeFacet(oldVotingFacet);
            }
        }

        // Deploy the NEW RootPoolVotingConfig (replaces SuperchainVotingConfig)
        RootPoolVotingConfig configImpl = new RootPoolVotingConfig();
        bytes memory initData = abi.encodeWithSelector(VotingConfig.initialize.selector, FORTY_ACRES_DEPLOYER);
        ERC1967Proxy configProxy = new ERC1967Proxy(address(configImpl), initData);
        _superchainVotingConfig = RootPoolVotingConfig(address(configProxy));

        // Deploy and register SuperchainVotingFacet wired to the new config
        DeploySuperchainVotingFacet deployer = new DeploySuperchainVotingFacet();
        deployer.deploy(address(_portfolioFactory), address(_superchainVotingConfig), address(_ve), address(_voter));
        vm.stopPrank();

        // Authorized caller (must be set as owner)
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);
        assertTrue(_portfolioManager.isAuthorizedCaller(_authorizedCaller), "Authorized caller should be set");
        vm.stopPrank();

        // Etch the ROOT_VOTING_REWARDS_FACTORY address with our mock so
        // setRecipient calls land on our recording mock.
        MockRootVotingRewardsFactory mockFactory = new MockRootVotingRewardsFactory();
        vm.etch(ROOT_VOTING_REWARDS_FACTORY, address(mockFactory).code);
    }

    // -----------------------------------------------------------------
    // Migrated negative tests (intent preserved from pre-migration suite)
    // -----------------------------------------------------------------

    function testInvalidSender() public {
        // vote() requires PortfolioManager.multicall as caller.
        vm.expectRevert();
        SuperchainVotingFacet(_portfolioAccount).vote(_tokenId, pools, weights);
    }

    function testVoteEmptyPools() public {
        vm.startPrank(_user);
        vm.expectRevert();
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            SuperchainVotingFacet.vote.selector, _tokenId, new address[](0), new uint256[](0)
        );
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function testVoteInvalidPool() public {
        // Pool is not approved → super.vote() reverts with PoolNotApproved.
        // (The factory-allowlist change does NOT remove the standard pool
        // approval check; this test ensures the underlying VotingFacet
        // gate is still in force.)
        vm.startPrank(_user);
        vm.expectRevert();
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(SuperchainVotingFacet.vote.selector, _tokenId, pools, weights);
        _portfolioManager.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // New coverage: factory-allowlist behavior (mock-based, Base fork)
    //
    // For these tests we mock the real Aerodrome voter's vote() to a no-op
    // so we can validate the SuperchainVotingFacet's own branches without
    // having to find a real on-chain pool/gauge to vote on. The pool is
    // approved via setApprovedPool so VotingFacet._vote() proceeds to the
    // underlying _voter.vote() (which we mock).
    // -----------------------------------------------------------------

    /// @dev (1) Pool whose factory() reverts → treated as not-superchain.
    function test_vote_poolFactoryReverts_isNotSuperchain() public {
        // Pool reverts on factory(); chainid() is irrelevant here.
        RevertingFactoryPool pool = new RevertingFactoryPool(FOREIGN_CHAIN);

        _setupRegistryAndMocks(address(pool), MOCK_FACTORY, /*registerFactory=*/ true);
        // Set minimum locked balance HIGH — if the facet (wrongly) treats
        // this as a superchain pool, _requireMinimumLockedBalance reverts.
        vm.prank(FORTY_ACRES_DEPLOYER);
        _superchainVotingConfig.setMinimumLockedBalancePerPool(type(uint128).max);

        _voteAndExpectNoSuperchainSideEffects(address(pool), FOREIGN_CHAIN);
    }

    /// @dev (2) Pool from a non-allowlisted factory → treated as not-superchain.
    function test_vote_poolFromUnlistedFactory_isNotSuperchain() public {
        MockRootPool pool = new MockRootPool(FOREIGN_CHAIN, OTHER_FACTORY);

        // Allowlist a DIFFERENT factory; pool's factory is not registered.
        _setupRegistryAndMocks(address(pool), MOCK_FACTORY, /*registerFactory=*/ true);
        vm.prank(FORTY_ACRES_DEPLOYER);
        _superchainVotingConfig.setMinimumLockedBalancePerPool(type(uint128).max);

        _voteAndExpectNoSuperchainSideEffects(address(pool), FOREIGN_CHAIN);
    }

    /// @dev (3) Pool from allowlisted factory but chainid() reverts → skip silently.
    function test_vote_chainidReverts_skipsSilently() public {
        RevertingChainidPool pool = new RevertingChainidPool(MOCK_FACTORY);

        _setupRegistryAndMocks(address(pool), MOCK_FACTORY, /*registerFactory=*/ true);
        vm.prank(FORTY_ACRES_DEPLOYER);
        _superchainVotingConfig.setMinimumLockedBalancePerPool(type(uint128).max);

        // Even though factory() identifies it as superchain, chainid()
        // revert MUST cause the facet to skip the pool — no setRecipient,
        // no minimum-balance enforcement (so the high minimum doesn't bite).
        _voteAndExpectNoSuperchainSideEffects(address(pool), /*expectedChainId=*/ 0);
    }

    /// @dev (4) chainid() == block.chainid → skip silently.
    function test_vote_localChainid_skipsSilently() public {
        MockRootPool pool = new MockRootPool(block.chainid, MOCK_FACTORY);

        _setupRegistryAndMocks(address(pool), MOCK_FACTORY, /*registerFactory=*/ true);
        vm.prank(FORTY_ACRES_DEPLOYER);
        _superchainVotingConfig.setMinimumLockedBalancePerPool(type(uint128).max);

        _voteAndExpectNoSuperchainSideEffects(address(pool), block.chainid);
    }

    /// @dev (5) chainid() == 0 → skip silently.
    function test_vote_zeroChainid_skipsSilently() public {
        MockRootPool pool = new MockRootPool(0, MOCK_FACTORY);

        _setupRegistryAndMocks(address(pool), MOCK_FACTORY, /*registerFactory=*/ true);
        vm.prank(FORTY_ACRES_DEPLOYER);
        _superchainVotingConfig.setMinimumLockedBalancePerPool(type(uint128).max);

        _voteAndExpectNoSuperchainSideEffects(address(pool), 0);
    }

    /// @dev (6) Happy path: allowlisted factory + foreign chainid → setRecipient
    ///         called once, minimum-balance enforced.
    function test_vote_superchainHappyPath_setsRecipientAndEnforcesMinimum() public {
        MockRootPool pool = new MockRootPool(FOREIGN_CHAIN, MOCK_FACTORY);

        _setupRegistryAndMocks(address(pool), MOCK_FACTORY, /*registerFactory=*/ true);

        // Real veNFT locked balance from the Base setUp (tokenId 84297).
        // Setting minimum to 1 ensures enforcement passes.
        vm.prank(FORTY_ACRES_DEPLOYER);
        _superchainVotingConfig.setMinimumLockedBalancePerPool(1);

        // Recipient is initially unset on the mock.
        assertEq(
            IRootVotingRewardsFactory(ROOT_VOTING_REWARDS_FACTORY).recipient(_portfolioAccount, FOREIGN_CHAIN),
            address(0),
            "recipient should start unset"
        );

        _multicallVote(address(pool));

        // After vote, recipient must be set to the portfolio account.
        assertEq(
            IRootVotingRewardsFactory(ROOT_VOTING_REWARDS_FACTORY).recipient(_portfolioAccount, FOREIGN_CHAIN),
            _portfolioAccount,
            "recipient should be set to portfolio account"
        );
    }

    /// @dev (7) Two superchain pools in one vote → both recognized,
    ///         minimum enforced as minimumPerPool * 2.
    function test_vote_twoSuperchainPools_enforcesScaledMinimum() public {
        MockRootPool poolA = new MockRootPool(FOREIGN_CHAIN, MOCK_FACTORY);
        // Use a different non-local chain id so each pool contributes.
        MockRootPool poolB = new MockRootPool(FOREIGN_CHAIN + 1, MOCK_FACTORY);

        // Approve both pools and register the factory.
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _superchainVotingConfig.setApprovedPool(address(poolA), true);
        _superchainVotingConfig.setApprovedPool(address(poolB), true);
        _superchainVotingConfig.setRootPoolFactory(MOCK_FACTORY, true);
        vm.stopPrank();
        _mockVoterVote();

        // Mock a large permanent veNFT lock so addLockedCollateral and
        // the per-pool minimum-balance check have a predictable value.
        uint256 lockedBalance = 1e24;
        _mockVeLocked(_tokenId, int128(uint128(lockedBalance)));

        vm.prank(FORTY_ACRES_DEPLOYER);
        _superchainVotingConfig.setMinimumLockedBalancePerPool(lockedBalance / 2);

        // Happy path with two pools
        {
            address[] memory votePools = new address[](2);
            votePools[0] = address(poolA);
            votePools[1] = address(poolB);
            uint256[] memory voteWeights = new uint256[](2);
            voteWeights[0] = 50e18;
            voteWeights[1] = 50e18;
            address[] memory portfolioFactories = new address[](1);
            portfolioFactories[0] = address(_portfolioFactory);
            bytes[] memory calldatas = new bytes[](1);
            calldatas[0] = abi.encodeWithSelector(
                SuperchainVotingFacet.vote.selector, _tokenId, votePools, voteWeights
            );
            vm.prank(_user);
            _portfolioManager.multicall(calldatas, portfolioFactories);
        }

        // Both recipients should be set
        assertEq(
            IRootVotingRewardsFactory(ROOT_VOTING_REWARDS_FACTORY).recipient(_portfolioAccount, FOREIGN_CHAIN),
            _portfolioAccount,
            "recipient[chainA] should be set"
        );
        assertEq(
            IRootVotingRewardsFactory(ROOT_VOTING_REWARDS_FACTORY).recipient(_portfolioAccount, FOREIGN_CHAIN + 1),
            _portfolioAccount,
            "recipient[chainB] should be set"
        );

        // Bump minimum so that minimum*2 > lockedBalance, then expect revert.
        vm.prank(FORTY_ACRES_DEPLOYER);
        _superchainVotingConfig.setMinimumLockedBalancePerPool(lockedBalance / 2 + 1);

        {
            address[] memory votePools = new address[](2);
            votePools[0] = address(poolA);
            votePools[1] = address(poolB);
            uint256[] memory voteWeights = new uint256[](2);
            voteWeights[0] = 50e18;
            voteWeights[1] = 50e18;
            address[] memory portfolioFactories = new address[](1);
            portfolioFactories[0] = address(_portfolioFactory);
            bytes[] memory calldatas = new bytes[](1);
            calldatas[0] = abi.encodeWithSelector(
                SuperchainVotingFacet.vote.selector, _tokenId, votePools, voteWeights
            );
            vm.prank(_user);
            vm.expectRevert();
            _portfolioManager.multicall(calldatas, portfolioFactories);
        }
    }

    // -----------------------------------------------------------------
    // New coverage: RootPoolVotingConfig access control & enumeration
    // -----------------------------------------------------------------

    /// @dev (8) setRootPoolFactory reverts when called by non-owner.
    function test_setRootPoolFactory_nonOwnerReverts() public {
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker)
        );
        _superchainVotingConfig.setRootPoolFactory(MOCK_FACTORY, true);
    }

    /// @dev (9) Events: emitted on add and remove; NOT on no-op.
    function test_setRootPoolFactory_emitsExpectedEvents() public {
        vm.startPrank(FORTY_ACRES_DEPLOYER);

        // Add fires RootPoolFactoryAdded
        vm.expectEmit(true, true, true, true, address(_superchainVotingConfig));
        emit RootPoolVotingConfig.RootPoolFactoryAdded(MOCK_FACTORY);
        _superchainVotingConfig.setRootPoolFactory(MOCK_FACTORY, true);

        // Adding the same factory again is a no-op — no event should fire.
        // We use vm.recordLogs to verify zero logs.
        vm.recordLogs();
        _superchainVotingConfig.setRootPoolFactory(MOCK_FACTORY, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no-op add should emit no logs");

        // Remove fires RootPoolFactoryRemoved
        vm.expectEmit(true, true, true, true, address(_superchainVotingConfig));
        emit RootPoolVotingConfig.RootPoolFactoryRemoved(MOCK_FACTORY);
        _superchainVotingConfig.setRootPoolFactory(MOCK_FACTORY, false);

        // Removing again is a no-op — no event.
        vm.recordLogs();
        _superchainVotingConfig.setRootPoolFactory(MOCK_FACTORY, false);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no-op remove should emit no logs");

        vm.stopPrank();
    }

    /// @dev (10) setRootPoolFactory(address(0), true) reverts with ZeroAddress.
    function test_setRootPoolFactory_zeroAddressReverts() public {
        vm.prank(FORTY_ACRES_DEPLOYER);
        vm.expectRevert(RootPoolVotingConfig.ZeroAddress.selector);
        _superchainVotingConfig.setRootPoolFactory(address(0), true);
    }

    /// @dev Even with approved=false, the zero address should be rejected
    ///      (current implementation checks before the branch).
    function test_setRootPoolFactory_zeroAddressRevertsOnRemove() public {
        vm.prank(FORTY_ACRES_DEPLOYER);
        vm.expectRevert(RootPoolVotingConfig.ZeroAddress.selector);
        _superchainVotingConfig.setRootPoolFactory(address(0), false);
    }

    /// @dev (11) Enumeration reflects adds and removes.
    function test_enumeration_reflectsAddsAndRemoves() public {
        // Initially empty
        assertEq(_superchainVotingConfig.getRootPoolFactoriesListLength(), 0, "starts empty");
        assertEq(_superchainVotingConfig.getRootPoolFactoriesList().length, 0, "list starts empty");

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _superchainVotingConfig.setRootPoolFactory(MOCK_FACTORY, true);
        _superchainVotingConfig.setRootPoolFactory(OTHER_FACTORY, true);
        vm.stopPrank();

        assertEq(_superchainVotingConfig.getRootPoolFactoriesListLength(), 2, "len == 2");
        address[] memory list = _superchainVotingConfig.getRootPoolFactoriesList();
        assertEq(list.length, 2, "list len == 2");

        // EnumerableSet preserves insertion order until removals.
        assertEq(list[0], MOCK_FACTORY, "list[0]");
        assertEq(list[1], OTHER_FACTORY, "list[1]");
        assertEq(_superchainVotingConfig.getRootPoolFactoryAtIndex(0), MOCK_FACTORY, "AtIndex(0)");
        assertEq(_superchainVotingConfig.getRootPoolFactoryAtIndex(1), OTHER_FACTORY, "AtIndex(1)");

        assertTrue(_superchainVotingConfig.isRootPoolFactory(MOCK_FACTORY), "isRootPoolFactory(mock)");
        assertTrue(_superchainVotingConfig.isRootPoolFactory(OTHER_FACTORY), "isRootPoolFactory(other)");
        assertFalse(_superchainVotingConfig.isRootPoolFactory(address(0xDEAD)), "isRootPoolFactory(unknown)");

        // Remove MOCK_FACTORY — EnumerableSet swaps last element into the
        // freed slot, so OTHER_FACTORY moves to index 0.
        vm.prank(FORTY_ACRES_DEPLOYER);
        _superchainVotingConfig.setRootPoolFactory(MOCK_FACTORY, false);

        assertEq(_superchainVotingConfig.getRootPoolFactoriesListLength(), 1, "len == 1 after remove");
        assertEq(_superchainVotingConfig.getRootPoolFactoryAtIndex(0), OTHER_FACTORY, "OTHER at index 0 after remove");
        assertFalse(_superchainVotingConfig.isRootPoolFactory(MOCK_FACTORY), "MOCK_FACTORY removed");

        // Remove last → empty
        vm.prank(FORTY_ACRES_DEPLOYER);
        _superchainVotingConfig.setRootPoolFactory(OTHER_FACTORY, false);
        assertEq(_superchainVotingConfig.getRootPoolFactoriesListLength(), 0, "empty after remove all");
    }

    /// @dev Extra: isSuperchainPool runtime probe semantics.
    function test_isSuperchainPool_runtimeProbe() public {
        MockRootPool listed = new MockRootPool(FOREIGN_CHAIN, MOCK_FACTORY);
        MockRootPool unlisted = new MockRootPool(FOREIGN_CHAIN, OTHER_FACTORY);
        RevertingFactoryPool reverting = new RevertingFactoryPool(FOREIGN_CHAIN);
        EmptyPool empty = new EmptyPool();

        vm.prank(FORTY_ACRES_DEPLOYER);
        _superchainVotingConfig.setRootPoolFactory(MOCK_FACTORY, true);

        assertTrue(_superchainVotingConfig.isSuperchainPool(address(listed)), "allowlisted");
        assertFalse(_superchainVotingConfig.isSuperchainPool(address(unlisted)), "non-allowlisted");
        assertFalse(_superchainVotingConfig.isSuperchainPool(address(reverting)), "factory() reverts");
        // EmptyPool has 3 bytes of (constructor-deployed) code → the call
        // returns success with empty data → ABI decode into address fails
        // inside the try → catch swallows it. Returns false as expected.
        assertFalse(_superchainVotingConfig.isSuperchainPool(address(empty)), "no factory()");
    }

    // -----------------------------------------------------------------
    // Migrated OP-fork test — preserves intent: verify minimum-balance
    // enforcement on a real OP root pool. Now uses factory allowlist.
    // -----------------------------------------------------------------

    function testVoteWithSuperchainPoolOnFork() public {
        uint256 fork = vm.createFork(vm.envString("OP_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(144601822);

        // Deploy and overwrite ROOT_VOTING_REWARDS_FACTORY with mock
        MockRootVotingRewardsFactory mockFactory = new MockRootVotingRewardsFactory();
        vm.etch(ROOT_VOTING_REWARDS_FACTORY, address(mockFactory).code);

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        PortfolioManager _pm = new PortfolioManager(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory portfolioFactory, ) =
            _pm.deployFactory(bytes32(keccak256(abi.encodePacked("velodrome-usdc"))));
        DeployPortfolioFactoryConfig configDeployer = new DeployPortfolioFactoryConfig();
        (PortfolioFactoryConfig portfolioFactoryConfig, , , ) =
            configDeployer.deploy(address(portfolioFactory), FORTY_ACRES_DEPLOYER);

        address ve = 0xFAf8FD17D9840595845582fCB047DF13f006787d;
        address voter = address(0x41C914ee0c7E1A5edCD0295623e6dC557B5aBf3C);

        // Deploy the NEW RootPoolVotingConfig
        RootPoolVotingConfig configImpl = new RootPoolVotingConfig();
        bytes memory initData = abi.encodeWithSelector(VotingConfig.initialize.selector, FORTY_ACRES_DEPLOYER);
        ERC1967Proxy configProxy = new ERC1967Proxy(address(configImpl), initData);
        RootPoolVotingConfig superchainVotingConfig = RootPoolVotingConfig(address(configProxy));

        DeploySuperchainVotingFacet deployer = new DeploySuperchainVotingFacet();
        deployer.deploy(address(portfolioFactory), address(superchainVotingConfig), address(ve), address(voter));

        DeployCollateralFacet deployCollateralFacet = new DeployCollateralFacet();
        deployCollateralFacet.deploy(address(portfolioFactory), address(ve));

        address loanContract = address(0xf132bD888897254521D13e2c401e109caABa06A7);
        vm.makePersistent(loanContract);

        vm.stopPrank();

        // Upgrade loan to LoanV2
        LoanV2 loanV2 = new LoanV2();
        vm.prank(IOwnable(loanContract).owner());
        LoanV2(loanContract).upgradeToAndCall(address(loanV2), new bytes(0));

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));
        vm.stopPrank();

        vm.prank(IOwnable(loanContract).owner());
        LoanV2(loanContract).setPortfolioFactory(address(portfolioFactory));

        vm.startPrank(FORTY_ACRES_DEPLOYER);
        portfolioFactoryConfig.setLoanContract(loanContract);

        // Real OP root pool
        address rootPool = 0x21cD02d175D61a4b4D6b62d8707186B1FedaaEAd;

        // Resolve the pool's actual factory and register it on the
        // allowlist. We could hardcode OP_V2_ROOT_POOL_FACTORY, but
        // pulling the value off the live pool is more robust against
        // upstream changes and proves the probe path matches reality.
        address poolFactory = IRootPool(rootPool).factory();
        assertTrue(poolFactory != address(0), "pool factory should be non-zero");
        superchainVotingConfig.setRootPoolFactory(poolFactory, true);
        // Standard pool approval still required by VotingFacet._vote()
        superchainVotingConfig.setApprovedPool(rootPool, true);

        uint256 tokenId = 5005;

        int128 lockedAmount = IVotingEscrow(ve).locked(tokenId).amount;
        uint256 lockedBalance = uint256(uint128(lockedAmount));
        assertGt(lockedBalance, 0, "veNFT should have locked balance");

        superchainVotingConfig.setMinimumLockedBalancePerPool(lockedBalance + 1);
        vm.stopPrank();

        address user = IVotingEscrow(ve).ownerOf(tokenId);
        vm.startPrank(user, user);
        address portfolioAccount = portfolioFactory.createAccount(user);
        IVotingEscrow(ve).transferFrom(user, portfolioAccount, tokenId);
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        address[] memory votePools = new address[](1);
        votePools[0] = rootPool;
        uint256[] memory voteWeights = new uint256[](1);
        voteWeights[0] = 100e18;

        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            SuperchainVotingFacet.vote.selector, tokenId, votePools, voteWeights
        );

        // Minimum > locked balance — must revert.
        vm.expectRevert();
        _pm.multicall(calldatas, portfolioFactories);
        vm.stopPrank();

        // Lower minimum and verify successful vote
        vm.prank(FORTY_ACRES_DEPLOYER);
        superchainVotingConfig.setMinimumLockedBalancePerPool(lockedBalance / 2);

        vm.startPrank(user, user);
        _pm.multicall(calldatas, portfolioFactories);

        assertEq(IVoter(address(voter)).lastVoted(tokenId), block.timestamp);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------

    /// @dev Approve the pool on the config, optionally allowlist the
    ///      factory, mock-out the underlying Voter.vote() and the veNFT
    ///      lock so CollateralManager doesn't trip on the expired lock
    ///      of the fork's tokenId.
    function _setupRegistryAndMocks(address pool, address factory, bool registerFactory) internal {
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _superchainVotingConfig.setApprovedPool(pool, true);
        if (registerFactory) {
            _superchainVotingConfig.setRootPoolFactory(factory, true);
        }
        vm.stopPrank();
        _mockVoterVote();
        // Default to a large permanent lock so addLockedCollateral and
        // _requireMinimumLockedBalance never trip. Tests that need a
        // specific lock amount call _mockVeLocked() directly.
        _mockVeLocked(_tokenId, int128(uint128(1e30)));
    }

    function _mockVoterVote() internal {
        // Real Aerodrome Voter would revert because pool isn't a real
        // gauge — short-circuit with a no-op mock.
        vm.mockCall(
            address(_voter),
            abi.encodeWithSelector(IVoter.vote.selector),
            bytes("")
        );
    }

    /// @dev Mock _ve.locked() to return a permanent lock with the given
    ///      amount, so CollateralManager.addLockedCollateral doesn't try
    ///      to call lockPermanent (which would revert because the real
    ///      veNFT's lock has expired at this fork block).
    function _mockVeLocked(uint256 tokenId, int128 amount) internal {
        IVotingEscrow.LockedBalance memory bal = IVotingEscrow.LockedBalance({
            amount: amount,
            end: 0,
            isPermanent: true
        });
        vm.mockCall(
            address(_ve),
            abi.encodeWithSelector(IVotingEscrow.locked.selector, tokenId),
            abi.encode(bal)
        );
    }

    function _multicallVote(address pool) internal {
        address[] memory votePools = new address[](1);
        votePools[0] = pool;
        uint256[] memory voteWeights = new uint256[](1);
        voteWeights[0] = 100e18;

        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            SuperchainVotingFacet.vote.selector, _tokenId, votePools, voteWeights
        );

        vm.prank(_user);
        _portfolioManager.multicall(calldatas, portfolioFactories);
    }

    /// @dev Vote on the given pool and assert that NO superchain side
    ///      effects occurred: no recipient set on the rewards factory,
    ///      and the high minimum-balance does NOT cause a revert (which
    ///      implicitly proves _requireMinimumLockedBalance was not run).
    function _voteAndExpectNoSuperchainSideEffects(address pool, uint256 expectedChainId) internal {
        // Pre-check: recipient is unset.
        if (expectedChainId != 0) {
            assertEq(
                IRootVotingRewardsFactory(ROOT_VOTING_REWARDS_FACTORY).recipient(_portfolioAccount, expectedChainId),
                address(0),
                "recipient should start unset"
            );
        }

        _multicallVote(pool);

        // Post-check: recipient still unset on the rewards factory.
        // If the facet (incorrectly) treated this as a superchain pool,
        // setRecipient would have been called.
        if (expectedChainId != 0) {
            assertEq(
                IRootVotingRewardsFactory(ROOT_VOTING_REWARDS_FACTORY).recipient(_portfolioAccount, expectedChainId),
                address(0),
                "recipient should remain unset for non-superchain pool"
            );
        }
        // The fact that we reached here without reverting on the high
        // minimum (set by the caller before invoking this helper) is
        // itself proof that _requireMinimumLockedBalance was skipped.
    }
}
