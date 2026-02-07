// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {YieldBasisFacet} from "../../../src/facets/account/yieldbasis/YieldBasisFacet.sol";
import {YieldBasisVotingFacet} from "../../../src/facets/account/yieldbasis/YieldBasisVotingFacet.sol";
import {DynamicCollateralFacet} from "../../../src/facets/account/collateral/DynamicCollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {ERC721ReceiverFacet} from "../../../src/facets/ERC721ReceiverFacet.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {DeployPortfolioAccountConfig} from "../../../script/portfolio_account/DeployPortfolioAccountConfig.s.sol";
import {IYieldBasisVotingEscrow} from "../../../src/interfaces/IYieldBasisVotingEscrow.sol";
import {IYieldBasisGaugeController} from "../../../src/interfaces/IYieldBasisGaugeController.sol";
import {IYieldBasisFeeDistributor} from "../../../src/interfaces/IYieldBasisFeeDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldBasisVotingEscrowAdapter} from "../../../src/adapters/YieldBasisVotingEscrowAdapter.sol";
import {YieldBasisFaucet} from "../../../src/faucets/YieldBasisFaucet.sol";
import {ILendingPool} from "../../../src/interfaces/ILendingPool.sol";

/**
 * @title MockLendingPool
 * @dev Mock lending pool for testing CollateralManager integration
 */
contract MockLendingPool is ILendingPool {
    address public immutable _lendingAsset;
    address public immutable _lendingVault;
    uint256 public _activeAssets;

    constructor(address lendingAsset_, address lendingVault_) {
        _lendingAsset = lendingAsset_;
        _lendingVault = lendingVault_;
    }

    function borrowFromPortfolio(uint256) external pure returns (uint256) {
        return 0; // No origination fee for testing
    }

    function payFromPortfolio(uint256, uint256) external pure {}

    function lendingAsset() external view returns (address) {
        return _lendingAsset;
    }

    function lendingVault() external view returns (address) {
        return _lendingVault;
    }

    function activeAssets() external view returns (uint256) {
        return _activeAssets;
    }

    function setActiveAssets(uint256 amount) external {
        _activeAssets = amount;
    }

    function getDebtBalance(address) external pure returns (uint256) {
        return 0;
    }
}

/**
 * @title MockVault
 * @dev Mock ERC4626 vault for testing - only implements asset() which is needed by CollateralManager
 */
contract MockVault {
    address public immutable _asset;

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() external view returns (address) {
        return _asset;
    }
}

contract YieldBasisVotingFacetTest is Test {
    // YieldBasis Protocol Addresses (Ethereum Mainnet)
    address public constant YB = 0x01791F726B4103694969820be083196cC7c045fF;
    address public constant VE_YB = 0x8235c179E9e84688FBd8B12295EfC26834dAC211;
    address public constant GAUGE_CONTROLLER = 0x1Be14811A3a06F6aF4fA64310a636e1Df04c1c21;
    address public constant FEE_DISTRIBUTOR = 0xD11b416573EbC59b6B2387DA0D2c0D1b3b1F7A90;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Test actors
    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public user = address(0x40ac2e);
    address public authorizedCaller = address(0xaaaaa);

    // Contracts
    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioAccountConfig public portfolioAccountConfig;
    LoanConfig public loanConfig;
    VotingConfig public votingConfig;
    SwapConfig public swapConfig;

    // Portfolio account
    address public portfolioAccount;

    // Facets
    YieldBasisFacet public yieldBasisFacet;
    YieldBasisVotingFacet public yieldBasisVotingFacet;
    DynamicCollateralFacet public collateralFacet;

    // YieldBasis contracts
    IYieldBasisVotingEscrow public veYB = IYieldBasisVotingEscrow(VE_YB);
    IYieldBasisGaugeController public gaugeController = IYieldBasisGaugeController(GAUGE_CONTROLLER);
    IERC20 public ybToken = IERC20(YB);

    // Mock lending contracts
    MockLendingPool public mockLendingPool;
    MockVault public mockVault;

    // Lock amount for tests
    uint256 public constant LOCK_AMOUNT = 1000 ether;

    function setUp() public {
        // Fork Ethereum mainnet
        uint256 fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);

        vm.startPrank(DEPLOYER);

        // Deploy PortfolioManager
        portfolioManager = new PortfolioManager(DEPLOYER);

        // Deploy factory with facet registry
        (portfolioFactory, facetRegistry) = portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("yieldbasis-test")))
        );

        // Deploy configs
        DeployPortfolioAccountConfig configDeployer = new DeployPortfolioAccountConfig();
        (portfolioAccountConfig, votingConfig, loanConfig, swapConfig) = configDeployer.deploy();

        // Deploy mock vault and lending pool for CollateralManager
        mockVault = new MockVault(USDC);
        mockLendingPool = new MockLendingPool(USDC, address(mockVault));

        // Configure the PortfolioAccountConfig with the mock lending pool
        portfolioAccountConfig.setLoanContract(address(mockLendingPool));

        // Fund the mock vault with USDC so getMaxLoan calculations work
        deal(USDC, address(mockVault), 1_000_000 * 1e6); // 1M USDC

        // Deploy DynamicCollateralFacet (required for enforceCollateralRequirements)
        collateralFacet = new DynamicCollateralFacet(
            address(portfolioFactory),
            address(portfolioAccountConfig),
            VE_YB
        );
        bytes4[] memory collateralSelectors = new bytes4[](9);
        collateralSelectors[0] = BaseCollateralFacet.addCollateral.selector;
        collateralSelectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        collateralSelectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        collateralSelectors[3] = BaseCollateralFacet.getUnpaidFees.selector;
        collateralSelectors[4] = BaseCollateralFacet.getMaxLoan.selector;
        collateralSelectors[5] = BaseCollateralFacet.getOriginTimestamp.selector;
        collateralSelectors[6] = BaseCollateralFacet.removeCollateral.selector;
        collateralSelectors[7] = BaseCollateralFacet.getCollateralToken.selector;
        collateralSelectors[8] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        facetRegistry.registerFacet(address(collateralFacet), collateralSelectors, "DynamicCollateralFacet");

        // Deploy YieldBasis VotingEscrow Adapter (adapts veYB to CollateralManager's IVotingEscrow interface)
        YieldBasisVotingEscrowAdapter veYBAdapter = new YieldBasisVotingEscrowAdapter(VE_YB);

        // Deploy YieldBasis Faucet (dispenses YB for bootstrapping locks)
        // Rate limit: 100 dispenses per hour
        YieldBasisFaucet faucet = new YieldBasisFaucet(
            address(portfolioManager),
            YB,
            .00001 ether,
            100,      // maxDispensesPerWindow
            1 hours   // windowDuration
        );
        // Fund the faucet
        deal(YB, address(faucet), 1000 ether);

        // Deploy YieldBasisFacet
        yieldBasisFacet = new YieldBasisFacet(
            address(portfolioFactory),
            address(portfolioAccountConfig),
            VE_YB,
            YB,
            address(veYBAdapter),
            address(faucet)
        );
        bytes4[] memory yieldBasisSelectors = new bytes4[](3);
        yieldBasisSelectors[0] = YieldBasisFacet.createLock.selector;
        yieldBasisSelectors[1] = YieldBasisFacet.increaseLock.selector;
        yieldBasisSelectors[2] = YieldBasisFacet.depositLock.selector;
        facetRegistry.registerFacet(address(yieldBasisFacet), yieldBasisSelectors, "YieldBasisFacet");

        // Deploy YieldBasisVotingFacet
        yieldBasisVotingFacet = new YieldBasisVotingFacet(
            address(portfolioFactory),
            address(portfolioAccountConfig),
            VE_YB,
            GAUGE_CONTROLLER,
            FEE_DISTRIBUTOR
        );
        bytes4[] memory votingSelectors = new bytes4[](2);
        votingSelectors[0] = YieldBasisVotingFacet.vote.selector;
        votingSelectors[1] = YieldBasisVotingFacet.defaultVote.selector;
        facetRegistry.registerFacet(address(yieldBasisVotingFacet), votingSelectors, "YieldBasisVotingFacet");

        // Deploy ERC721ReceiverFacet (needed for veYB NFT transfers)
        ERC721ReceiverFacet erc721ReceiverFacet = new ERC721ReceiverFacet();
        bytes4[] memory erc721ReceiverSelectors = new bytes4[](1);
        erc721ReceiverSelectors[0] = ERC721ReceiverFacet.onERC721Received.selector;
        facetRegistry.registerFacet(address(erc721ReceiverFacet), erc721ReceiverSelectors, "ERC721ReceiverFacet");

        // Set authorized caller
        portfolioManager.setAuthorizedCaller(authorizedCaller, true);

        vm.stopPrank();

        // Create portfolio account for user
        portfolioAccount = portfolioFactory.createAccount(user);

        // Deal YB tokens to user
        deal(YB, user, LOCK_AMOUNT * 10);

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    // ============ Create Lock Tests ============

    function testCreateLock() public {
        vm.startPrank(user);

        // Approve portfolio account to spend YB tokens
        ybToken.approve(portfolioAccount, LOCK_AMOUNT);

        // Create lock via multicall
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisFacet.createLock.selector, LOCK_AMOUNT);

        portfolioManager.multicall(calldatas, factories);

        vm.stopPrank();

        // Verify lock was created
        IYieldBasisVotingEscrow.LockedBalance memory lockedBalance = veYB.locked(portfolioAccount);
        assertTrue(lockedBalance.amount > 0, "Lock should exist");
        // veYB rounds down slightly due to lock duration calculation, allow 0.01% tolerance
        assertApproxEqAbs(uint256(uint128(lockedBalance.amount)), LOCK_AMOUNT, LOCK_AMOUNT / 10000, "Lock amount should be ~1000 YB");
        // With infinite lock, end time is type(uint256).max
        assertEq(lockedBalance.end, type(uint256).max, "Lock should be infinite (end == max uint256)");
    }

    function testCreateLockThenVote() public {
        // First create a lock
        vm.startPrank(user);

        ybToken.approve(portfolioAccount, LOCK_AMOUNT);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisFacet.createLock.selector, LOCK_AMOUNT);

        portfolioManager.multicall(calldatas, factories);

        // Verify lock exists
        assertTrue(veYB.balanceOf(portfolioAccount) > 0, "Lock should exist before voting");

        // Find an active (non-killed) gauge
        uint256 nGauges = gaugeController.n_gauges();
        require(nGauges > 0, "No gauges available for voting");

        address gauge;
        for (uint256 i = 0; i < nGauges; i++) {
            address g = gaugeController.gauges(i);
            if (!gaugeController.is_killed(g)) {
                gauge = g;
                break;
            }
        }
        require(gauge != address(0), "No active gauges found");
        console.log("Voting on gauge:", gauge);

        // Vote on the gauge
        address[] memory gauges = new address[](1);
        gauges[0] = gauge;

        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000; // 100% of voting power

        calldatas[0] = abi.encodeWithSelector(YieldBasisVotingFacet.vote.selector, gauges, weights);

        portfolioManager.multicall(calldatas, factories);

        vm.stopPrank();

        // Verify vote was recorded
        uint256 voteUserPower = gaugeController.vote_user_power(portfolioAccount);
        assertEq(voteUserPower, 10000, "Vote user power should be 10000 bps");
    }

    function testVoteOnMultipleGauges() public {
        // First create a lock
        vm.startPrank(user);

        ybToken.approve(portfolioAccount, LOCK_AMOUNT);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisFacet.createLock.selector, LOCK_AMOUNT);

        portfolioManager.multicall(calldatas, factories);

        // Find two active (non-killed) gauges
        uint256 nGauges = gaugeController.n_gauges();
        address[] memory activeGauges = new address[](2);
        uint256 found = 0;
        for (uint256 i = 0; i < nGauges && found < 2; i++) {
            address g = gaugeController.gauges(i);
            if (!gaugeController.is_killed(g)) {
                activeGauges[found] = g;
                found++;
            }
        }
        require(found >= 2, "Need at least 2 active gauges for this test");

        console.log("Voting on gauge 1:", activeGauges[0]);
        console.log("Voting on gauge 2:", activeGauges[1]);

        // Vote on multiple gauges (50% each)
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000; // 50%
        weights[1] = 5000; // 50%

        calldatas[0] = abi.encodeWithSelector(YieldBasisVotingFacet.vote.selector, activeGauges, weights);

        portfolioManager.multicall(calldatas, factories);



        // Verify total vote power used
        uint256 voteUserPower = gaugeController.vote_user_power(portfolioAccount);
        assertEq(voteUserPower, 10000, "Total vote power should be 10000 bps");

        // Store the gauges we already voted on
        address firstGauge = activeGauges[0];
        address secondGauge = activeGauges[1];

        // vote for two seperate pools with 50% each so it should revert becuase the old pool still has voting power
        // Reset found and find 2 new gauges (different from the ones we already voted on)
        found = 0;
        for (uint256 i = 0; i < nGauges && found < 2; i++) {
            address g = gaugeController.gauges(i);
            if (!gaugeController.is_killed(g)) {
                // skip the gauges we already voted on
                if (g == firstGauge || g == secondGauge) {
                    continue;
                }
                activeGauges[found] = g;
                found++;
            }
        }
        require(found >= 2, "Need at least 2 additional active gauges for this test");

        calldatas[0] = abi.encodeWithSelector(YieldBasisVotingFacet.vote.selector, activeGauges, weights);


        // skip 11 days
        vm.warp(block.timestamp + 11 days);
        vm.roll(block.number + 1);

        console.log("Voting on gauge 1:", activeGauges[0]);
        console.log("Voting on gauge 2:", activeGauges[1]);

        vm.expectRevert();
        portfolioManager.multicall(calldatas, factories);

        // vote with all 4 gauges but set first two to 0% and last two to 100%
        address[] memory allGauges = new address[](4);
        allGauges[0] = firstGauge;
        allGauges[1] = secondGauge;
        allGauges[2] = activeGauges[0];
        allGauges[3] = activeGauges[1];

        uint256[] memory allWeights = new uint256[](4);
        allWeights[0] = 0;
        allWeights[1] = 0;
        allWeights[2] = 5000;
        allWeights[3] = 5000;

        calldatas[0] = abi.encodeWithSelector(YieldBasisVotingFacet.vote.selector, allGauges, allWeights);
        portfolioManager.multicall(calldatas, factories);


        // skip 11 days
        vm.warp(block.timestamp + 22 days);
        vm.roll(block.number + 2);
        calldatas[0] = abi.encodeWithSelector(YieldBasisVotingFacet.vote.selector, allGauges, allWeights);
        portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
        
    }

    function testDefaultVoteOnMultipleGauges() public {
        // First create a lock
        vm.startPrank(user);

        ybToken.approve(portfolioAccount, LOCK_AMOUNT);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisFacet.createLock.selector, LOCK_AMOUNT);

        portfolioManager.multicall(calldatas, factories);

        // Find two active (non-killed) gauges
        uint256 nGauges = gaugeController.n_gauges();
        address[] memory activeGauges = new address[](2);
        uint256 found = 0;
        for (uint256 i = 0; i < nGauges && found < 2; i++) {
            address g = gaugeController.gauges(i);
            if (!gaugeController.is_killed(g)) {
                activeGauges[found] = g;
                found++;
            }
        }
        require(found >= 2, "Need at least 2 active gauges for this test");

        console.log("Voting on gauge 1:", activeGauges[0]);
        console.log("Voting on gauge 2:", activeGauges[1]);

        // Vote on multiple gauges (50% each)
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000; // 50%
        weights[1] = 5000; // 50%

        calldatas[0] = abi.encodeWithSelector(YieldBasisVotingFacet.vote.selector, activeGauges, weights);

        portfolioManager.multicall(calldatas, factories);



        // Verify total vote power used
        uint256 voteUserPower = gaugeController.vote_user_power(portfolioAccount);
        assertEq(voteUserPower, 10000, "Total vote power should be 10000 bps");

        // Store the gauges we already voted on
        address firstGauge = activeGauges[0];
        address secondGauge = activeGauges[1];

        // vote for two seperate pools with 50% each so it should revert becuase the old pool still has voting power
        // Reset found and find 2 new gauges (different from the ones we already voted on)
        found = 0;
        for (uint256 i = 0; i < nGauges && found < 2; i++) {
            address g = gaugeController.gauges(i);
            if (!gaugeController.is_killed(g)) {
                // skip the gauges we already voted on
                if (g == firstGauge || g == secondGauge) {
                    continue;
                }
                activeGauges[found] = g;
                found++;
            }
        }
        require(found >= 2, "Need at least 2 additional active gauges for this test");

        vm.stopPrank();

        // skip 16 days
        vm.warp(block.timestamp + 16 days);
        vm.roll(block.number + 1);

        console.log("Voting on gauge 1:", activeGauges[0]);
        console.log("Voting on gauge 2:", activeGauges[1]);

        // Try to vote on new gauges - should revert because old gauges still have voting power allocated
        // The gauge controller prevents allocating more than 100% total voting power
        vm.prank(authorizedCaller);
        vm.expectRevert();
        YieldBasisVotingFacet(portfolioAccount).defaultVote(activeGauges, weights);

        // vote with all 4 gauges but set first two to 0% and last two to 100%
        address[] memory allGauges = new address[](4);
        allGauges[0] = firstGauge;
        allGauges[1] = secondGauge;
        allGauges[2] = activeGauges[0];
        allGauges[3] = activeGauges[1];

        uint256[] memory allWeights = new uint256[](4);
        allWeights[0] = 0;
        allWeights[1] = 0;
        allWeights[2] = 5000;
        allWeights[3] = 5000;

        // This should work because we're setting the old gauges to 0% and new ones to 50% each
        vm.prank(authorizedCaller);
        YieldBasisVotingFacet(portfolioAccount).defaultVote(allGauges, allWeights);

        // Verify voting power is correctly allocated
        voteUserPower = gaugeController.vote_user_power(portfolioAccount);
        assertEq(voteUserPower, 10000, "Total vote power should be 10000 bps");

        // Try to vote again immediately - should revert because cooldown not met (need 15 days)
        vm.prank(authorizedCaller);
        vm.expectRevert();
        YieldBasisVotingFacet(portfolioAccount).defaultVote(allGauges, allWeights);

        // skip 14 days (cooldown should not be met - less than 15 days)
        vm.warp(block.timestamp + 12 days);
        vm.roll(block.number + 1);
        vm.expectRevert();
        vm.prank(authorizedCaller);
        YieldBasisVotingFacet(portfolioAccount).defaultVote(allGauges, allWeights);


        // skip 15 days (cooldown should be met - exactly 15 days)
        vm.warp(block.timestamp + 15 days);
        vm.roll(block.number + 1);
        vm.prank(authorizedCaller);
        YieldBasisVotingFacet(portfolioAccount).defaultVote(allGauges, allWeights);

        // Verify voting power is still correctly allocated
        voteUserPower = gaugeController.vote_user_power(portfolioAccount);
        assertEq(voteUserPower, 10000, "Total vote power should still be 10000 bps");
        
    }

    // ============ Access Control Tests ============

    function testVoteRevertsWhenNotCalledViaMulticall() public {
        // First create a lock
        vm.startPrank(user);

        ybToken.approve(portfolioAccount, LOCK_AMOUNT);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisFacet.createLock.selector, LOCK_AMOUNT);

        portfolioManager.multicall(calldatas, factories);

        // Try to call vote directly (should fail)
        address gauge = gaugeController.gauges(0);
        address[] memory gauges = new address[](1);
        gauges[0] = gauge;

        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;

        vm.expectRevert();
        YieldBasisVotingFacet(portfolioAccount).vote(gauges, weights);

        vm.stopPrank();
    }

    function testDefaultVoteRevertsWhenNotAuthorizedCaller() public {
        // First create a lock
        vm.startPrank(user);

        ybToken.approve(portfolioAccount, LOCK_AMOUNT);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisFacet.createLock.selector, LOCK_AMOUNT);

        portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        // Try to call defaultVote as non-authorized caller (should fail)
        address gauge = gaugeController.gauges(0);
        address[] memory gauges = new address[](1);
        gauges[0] = gauge;

        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;

        vm.prank(user); // user is not an authorized caller
        vm.expectRevert();
        YieldBasisVotingFacet(portfolioAccount).defaultVote(gauges, weights);
    }

    function testDefaultVoteAsAuthorizedCaller() public {
        // First create a lock via user
        vm.startPrank(user);

        ybToken.approve(portfolioAccount, LOCK_AMOUNT);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisFacet.createLock.selector, LOCK_AMOUNT);

        portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        // Find an active gauge
        uint256 nGauges = gaugeController.n_gauges();
        address gauge;
        for (uint256 i = 0; i < nGauges; i++) {
            address g = gaugeController.gauges(i);
            if (!gaugeController.is_killed(g)) {
                gauge = g;
                break;
            }
        }
        require(gauge != address(0), "No active gauges found");

        address[] memory gauges = new address[](1);
        gauges[0] = gauge;

        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;

        vm.prank(authorizedCaller);
        YieldBasisVotingFacet(portfolioAccount).defaultVote(gauges, weights);

        // Verify vote was recorded
        uint256 voteUserPower = gaugeController.vote_user_power(portfolioAccount);
        assertEq(voteUserPower, 10000, "Vote user power should be 10000 bps");
    }

    // ============ Edge Cases ============

    function testCannotVoteWithoutLock() public {
        // Get a gauge
        address gauge = gaugeController.gauges(0);
        address[] memory gauges = new address[](1);
        gauges[0] = gauge;

        uint256[] memory weights = new uint256[](1);
        weights[0] = 10000;

        // Try to vote without creating a lock first
        vm.startPrank(user);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisVotingFacet.vote.selector, gauges, weights);

        // Should revert because no voting power
        vm.expectRevert();
        portfolioManager.multicall(calldatas, factories);

        vm.stopPrank();
    }

    function testDefaultVoteInvalidWeightReverts() public {
        // First create a lock
        vm.startPrank(user);

        ybToken.approve(portfolioAccount, LOCK_AMOUNT);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisFacet.createLock.selector, LOCK_AMOUNT);

        portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        // Try to call defaultVote with weight != 10000
        address gauge = gaugeController.gauges(0);
        address[] memory gauges = new address[](1);
        gauges[0] = gauge;

        uint256[] memory weights = new uint256[](1);
        weights[0] = 5000; // Only 50% - should revert

        vm.prank(authorizedCaller);
        vm.expectRevert(YieldBasisVotingFacet.InvalidWeight.selector);
        YieldBasisVotingFacet(portfolioAccount).defaultVote(gauges, weights);
    }

    function testIncreaseLock() public {
        // Create initial lock
        vm.startPrank(user);

        ybToken.approve(portfolioAccount, LOCK_AMOUNT * 2);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisFacet.createLock.selector, LOCK_AMOUNT);

        portfolioManager.multicall(calldatas, factories);

        // Increase lock
        calldatas[0] = abi.encodeWithSelector(YieldBasisFacet.increaseLock.selector, LOCK_AMOUNT);
        portfolioManager.multicall(calldatas, factories);

        vm.stopPrank();

        // Verify increased amount (veYB rounds down slightly due to lock duration calculation)
        IYieldBasisVotingEscrow.LockedBalance memory lockedBalance = veYB.locked(portfolioAccount);
        assertApproxEqAbs(uint256(uint128(lockedBalance.amount)), LOCK_AMOUNT * 2, LOCK_AMOUNT * 2 / 10000, "Lock amount should be ~2000 YB");
        // With infinite lock, end time is type(uint256).max
        assertEq(lockedBalance.end, type(uint256).max, "Lock should be infinite (end == max uint256)");
    }

    // ============ Infinite Lock Tests ============

    function testCreateLockEnablesInfiniteLock() public {
        vm.startPrank(user);

        ybToken.approve(portfolioAccount, LOCK_AMOUNT);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisFacet.createLock.selector, LOCK_AMOUNT);

        portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();

        // Verify infinite lock is enabled (indicated by lock.end == type(uint256).max)
        IYieldBasisVotingEscrow.LockedBalance memory lockedBalance = veYB.locked(portfolioAccount);
        assertEq(lockedBalance.end, type(uint256).max, "Infinite lock should be enabled after createLock (end == max uint256)");
    }

    // ============ DepositLock Tests ============

    function testDepositLockWithoutExistingLockUsesFaucet() public {
        // User creates their own veYB lock directly (not via portfolio account)
        vm.startPrank(user);
        ybToken.approve(VE_YB, LOCK_AMOUNT);
        uint256 maxUnlockTime = ((block.timestamp + 4 * 365 days) / 7 days) * 7 days;
        veYB.create_lock(LOCK_AMOUNT, maxUnlockTime);

        // Enable infinite lock on user's lock (required for transfer)
        veYB.infinite_lock_toggle();

        uint256 userTokenId = veYB.tokenOfOwnerByIndex(user, 0);

        // Approve the portfolio account to transfer the veYB
        (bool success,) = VE_YB.call(abi.encodeWithSignature("setApprovalForAll(address,bool)", portfolioAccount, true));
        require(success, "setApprovalForAll failed");

        // Deposit the lock into portfolio account that has NO existing lock
        // The faucet will be used to bootstrap a lock first
        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisFacet.depositLock.selector, userTokenId);

        // Should succeed - faucet bootstraps a lock, then user's lock is deposited and merged
        portfolioManager.multicall(calldatas, factories);

        vm.stopPrank();

        // Verify the lock was created and merged (faucet amount + user's lock)
        uint256 finalAmount = uint256(uint128(veYB.locked(portfolioAccount).amount));
        // Should be approximately LOCK_AMOUNT + 0.00001 ether (faucet dispense amount)
        assertApproxEqAbs(finalAmount, LOCK_AMOUNT + 0.00001 ether, (LOCK_AMOUNT + 0.00001 ether) / 10000, "Final lock should be ~LOCK_AMOUNT + faucet amount");
    }

    function testDepositLockSucceedsWithExistingLock() public {
        // First create a lock in the portfolio account
        vm.startPrank(user);

        ybToken.approve(portfolioAccount, LOCK_AMOUNT);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(YieldBasisFacet.createLock.selector, LOCK_AMOUNT);

        portfolioManager.multicall(calldatas, factories);

        // Verify initial lock amount
        uint256 initialAmount = uint256(uint128(veYB.locked(portfolioAccount).amount));
        assertApproxEqAbs(initialAmount, LOCK_AMOUNT, LOCK_AMOUNT / 10000, "Initial lock should be ~LOCK_AMOUNT");

        // User creates another veYB lock directly to deposit
        deal(YB, user, LOCK_AMOUNT); // Give user more YB tokens
        ybToken.approve(VE_YB, LOCK_AMOUNT);
        uint256 maxUnlockTime = ((block.timestamp + 4 * 365 days) / 7 days) * 7 days;
        veYB.create_lock(LOCK_AMOUNT, maxUnlockTime);

        // Enable infinite lock on user's lock (required for transfer)
        veYB.infinite_lock_toggle();

        uint256 userTokenId = veYB.tokenOfOwnerByIndex(user, 0);

        // Approve the portfolio account to transfer the veYB
        (bool success,) = VE_YB.call(abi.encodeWithSignature("setApprovalForAll(address,bool)", portfolioAccount, true));
        require(success, "setApprovalForAll failed");

        // Now deposit the lock into portfolio account that HAS an existing lock
        calldatas[0] = abi.encodeWithSelector(YieldBasisFacet.depositLock.selector, userTokenId);
        portfolioManager.multicall(calldatas, factories);

        vm.stopPrank();

        // Verify the lock amount increased (positions merged)
        uint256 finalAmount = uint256(uint128(veYB.locked(portfolioAccount).amount));
        assertApproxEqAbs(finalAmount, LOCK_AMOUNT * 2, LOCK_AMOUNT * 2 / 10000, "Final lock should be ~2x LOCK_AMOUNT after deposit");
    }
}
