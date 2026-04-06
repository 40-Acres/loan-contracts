// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/**
 * @title SuperchainClaimingFacet Integration Test
 * @dev Fork test against Optimism mainnet verifying that SuperchainClaimingFacet
 *      correctly claims rewards from reward contracts by calling getReward
 *      directly from the portfolio (which owns the veNFT).
 *
 * Issue Context:
 * The existing ClaimingFacet routes through Voter.claimFees, which internally calls
 * getReward on reward contracts. For root reward contracts (superchain), those contracts
 * check isApprovedOrOwner(caller, tokenId) -- which fails when the Voter is the caller
 * because the Voter is NOT the NFT owner or approved.
 * SuperchainClaimingFacet bypasses the Voter entirely and calls getReward directly
 * from the portfolio account, which owns the veNFT.
 *
 * Test Strategy:
 * Uses token 5005 on Optimism at block 144601822. Votes on a superchain pool, advances
 * to the next epoch, then verifies claiming works through the new facet. Also verifies
 * that the Voter.claimFees path fails for root reward contracts.
 */

import {Test, console} from "forge-std/Test.sol";
import {SuperchainClaimingFacet} from "../../../../src/facets/account/claim/SuperchainClaimingFacet.sol";
import {DeploySuperchainClaimingFacet} from "../../../../script/portfolio_account/facets/DeploySuperchainClaimingFacet.s.sol";
import {DeploySuperchainVotingFacet} from "../../../../script/portfolio_account/facets/DeploySuperchainVoting.s.sol";
import {DeployPortfolioFactoryConfig} from "../../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";
import {DeployCollateralFacet} from "../../../../script/portfolio_account/facets/DeployCollateralFacet.s.sol";
import {DeployClaimingFacet} from "../../../../script/portfolio_account/facets/DeployClaimingFacet.s.sol";
import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../../../src/interfaces/IVoter.sol";
import {IReward} from "../../../../src/interfaces/IReward.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {SuperchainVotingConfig} from "../../../../src/facets/account/config/SuperchainVotingConfig.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../../src/facets/account/config/SwapConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {SuperchainVotingFacet} from "../../../../src/facets/account/vote/SuperchainVoting.sol";
import {ClaimingFacet} from "../../../../src/facets/account/claim/ClaimingFacet.sol";

import {Loan as LoanV2} from "../../../../src/LoanV2.sol";
import {Loan} from "../../../../src/Loan.sol";
import {Vault} from "../../../../src/VaultV2.sol";
import {ProtocolTimeLibrary} from "../../../../src/libraries/ProtocolTimeLibrary.sol";
import {IRewardsDistributor} from "../../../../src/interfaces/IRewardsDistributor.sol";

interface IOwnable {
    function owner() external view returns (address);
}

contract SuperchainClaimingFacetTest is Test {
    // Optimism mainnet addresses
    address constant VE = 0xFAf8FD17D9840595845582fCB047DF13f006787d;
    address constant VOTER = 0x41C914ee0c7E1A5edCD0295623e6dC557B5aBf3C;
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant REWARDS_DISTRIBUTOR = 0x9D4736EC60715e71aFe72973f7885DCBC21EA99b;

    // Fee tokens on Optimism
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDT0 = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;

    // Real root pool on Optimism (implements IRootPool.chainid() → 1868 Soneium)
    // Pair: USDT0/WETH
    address constant SUPERCHAIN_POOL = 0x21cD02d175D61a4b4D6b62d8707186B1FedaaEAd;

    // Fee voting reward for the root pool's gauge (from Voter.gaugeToFees(gauge))
    address constant POOL_FEE_REWARD = 0x22796dEA87c141aBEc616E38247074e9e51C6B20;
    // Bribe voting reward for the root pool's gauge (from Voter.gaugeToBribe(gauge))
    address constant POOL_BRIBE_REWARD = 0x2be8990C7057018b29Da8Af2F5b8c397babB2203;

    // Test NFT
    uint256 constant TOKEN_ID = 5005;

    // Deployer
    address constant FORTY_ACRES_DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;

    // Root voting rewards factory
    address constant ROOT_VOTING_REWARDS_FACTORY = 0x7dc9fd82f91B36F416A89f5478375e4a79f4Fb2F;

    // Fork block
    uint256 constant FORK_BLOCK = 144601822;

    // Deployed contracts
    PortfolioManager pm;
    PortfolioFactory portfolioFactory;
    FacetRegistry facetRegistry;
    SuperchainVotingConfig superchainVotingConfig;
    LoanConfig loanConfig;
    SwapConfig swapConfig;
    address portfolioAccount;
    address user;

    function setUp() public {
        vm.createSelectFork(vm.envString("OP_RPC_URL"), FORK_BLOCK);

        vm.startPrank(FORTY_ACRES_DEPLOYER);

        // Deploy PortfolioManager and Factory
        pm = new PortfolioManager(FORTY_ACRES_DEPLOYER);
        (portfolioFactory, facetRegistry) = pm.deployFactory(
            bytes32(keccak256(abi.encodePacked("velodrome-usdc")))
        );

        // Deploy configs
        DeployPortfolioFactoryConfig configDeployer = new DeployPortfolioFactoryConfig();
        PortfolioFactoryConfig portfolioFactoryConfig;
        VotingConfig votingConfig;
        (portfolioFactoryConfig, votingConfig, loanConfig, swapConfig) = configDeployer.deploy(address(portfolioFactory), FORTY_ACRES_DEPLOYER);

        // Deploy SuperchainVotingConfig
        SuperchainVotingConfig scVotingConfigImpl = new SuperchainVotingConfig();
        bytes memory initData = abi.encodeWithSelector(
            VotingConfig.initialize.selector,
            FORTY_ACRES_DEPLOYER
        );
        ERC1967Proxy scVotingConfigProxy = new ERC1967Proxy(address(scVotingConfigImpl), initData);
        superchainVotingConfig = SuperchainVotingConfig(address(scVotingConfigProxy));

        // Deploy SuperchainVotingFacet
        DeploySuperchainVotingFacet votingDeployer = new DeploySuperchainVotingFacet();
        votingDeployer.deploy(address(portfolioFactory), address(superchainVotingConfig), VE, VOTER);

        // Deploy SuperchainClaimingFacet
        DeploySuperchainClaimingFacet claimingDeployer = new DeploySuperchainClaimingFacet();
        claimingDeployer.deploy(address(portfolioFactory));

        // Deploy ClaimingFacet (used to demonstrate the Voter.claimFees path)
        DeployClaimingFacet baseClaimingDeployer = new DeployClaimingFacet();
        baseClaimingDeployer.deploy(
            address(portfolioFactory), VE, VOTER, REWARDS_DISTRIBUTOR,
            address(loanConfig), address(swapConfig), address(0)
        );

        // Deploy CollateralFacet
        DeployCollateralFacet collateralDeployer = new DeployCollateralFacet();
        collateralDeployer.deploy(address(portfolioFactory), VE);

        // Deploy loan infrastructure
        Loan loanImpl = new Loan();
        ERC1967Proxy loanProxy = new ERC1967Proxy(address(loanImpl), "");
        Vault vaultImpl = new Vault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), "");
        Vault vault = Vault(address(vaultProxy));
        vault.initialize(USDC, address(loanProxy), "40-USDC-VAULT", "40-USDC-VAULT");
        Loan(address(loanProxy)).initialize(address(vault), USDC);

        LoanV2 loanV2Impl = new LoanV2();
        LoanV2(address(loanProxy)).upgradeToAndCall(address(loanV2Impl), new bytes(0));
        LoanV2(address(loanProxy)).setPortfolioFactory(address(portfolioFactory));

        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));
        portfolioFactoryConfig.setLoanContract(address(loanProxy));

        // Configure superchain pool (real root pool with chainid())
        superchainVotingConfig.setApprovedPool(SUPERCHAIN_POOL, true);
        superchainVotingConfig.setSuperchainPool(SUPERCHAIN_POOL, true);

        // Set minimum locked balance
        int128 lockedAmount = IVotingEscrow(VE).locked(TOKEN_ID).amount;
        uint256 lockedBalance = uint256(uint128(lockedAmount));
        superchainVotingConfig.setMinimumLockedBalancePerPool(lockedBalance / 2);

        // Set authorized caller
        pm.setAuthorizedCaller(FORTY_ACRES_DEPLOYER, true);

        vm.stopPrank();

        // Get user and create portfolio
        user = IVotingEscrow(VE).ownerOf(TOKEN_ID);
        require(user != address(0), "Token owner should not be zero address");

        vm.startPrank(user, user);
        portfolioAccount = portfolioFactory.createAccount(user);
        IVotingEscrow(VE).transferFrom(user, portfolioAccount, TOKEN_ID);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
    }

    // -----------------------------------------------------------------------
    // Test 1: Demonstrate the problem - Voter.claimFees reverts for root contracts
    // -----------------------------------------------------------------------

    function testRevert_voterClaimFees_failsForRootRewardContracts() public {
        // Vote on the superchain pool
        _voteOnSuperchainPool();

        // Advance to next epoch
        uint256 nextEpochStart = ProtocolTimeLibrary.epochNext(block.timestamp);
        vm.warp(nextEpochStart + 3 hours);
        vm.roll(block.number + 1);

        // Attempt to claim fees through ClaimingFacet (which routes through Voter.claimFees).
        // Using the root pool's fee reward contract via Voter.claimFees should fail because
        // the Voter contract is not isApprovedOrOwner on root reward contracts.
        address[] memory fees = new address[](1);
        fees[0] = POOL_FEE_REWARD;

        address[][] memory tokens = new address[][](1);
        tokens[0] = new address[](2);
        tokens[0][0] = WETH;
        tokens[0][1] = USDT0;

        // ClaimingFacet.claimFees -> Voter.claimFees -> rootRewardContract.getReward
        // This reverts because Voter is NOT isApprovedOrOwner on the root contract.
        // Must call as authorized caller (ClaimingFacet uses AccessControl).
        vm.startPrank(FORTY_ACRES_DEPLOYER, FORTY_ACRES_DEPLOYER);
        vm.expectRevert();
        ClaimingFacet(portfolioAccount).claimFees(fees, tokens, TOKEN_ID);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Test 2: Demonstrate the fix - SuperchainClaimingFacet direct call works
    // -----------------------------------------------------------------------

    function test_claimSuperchainRewards_succeedsFromPortfolio() public {
        // Vote on superchain pool
        _voteOnSuperchainPool();

        // Advance to next epoch so rewards become claimable
        uint256 nextEpochStart = ProtocolTimeLibrary.epochNext(block.timestamp);
        vm.warp(nextEpochStart + 3 hours);
        vm.roll(block.number + 1);

        // Record balances before
        uint256 wethBefore = IERC20(WETH).balanceOf(portfolioAccount);
        uint256 xveloBefore = IERC20(USDT0).balanceOf(portfolioAccount);

        // Use the regular fee voting reward contract (which the portfolio CAN call
        // getReward on because it owns the veNFT). This demonstrates the core mechanism.
        address[] memory rewardContracts = new address[](1);
        rewardContracts[0] = POOL_FEE_REWARD;

        address[][] memory tokens = new address[][](1);
        tokens[0] = new address[](2);
        tokens[0][0] = WETH;
        tokens[0][1] = USDT0;

        // Call claimSuperchainRewards through the diamond
        // Portfolio -> SuperchainClaimingFacet.claimSuperchainRewards -> rewardContract.getReward
        // Works because portfolio is the NFT owner (isApprovedOrOwner passes)
        vm.startPrank(user, user);
        _multicallClaim(rewardContracts, tokens);
        vm.stopPrank();

        // The call succeeded without revert -- this is the primary assertion.
        // Balances should not decrease.
        uint256 wethAfter = IERC20(WETH).balanceOf(portfolioAccount);
        uint256 xveloAfter = IERC20(USDT0).balanceOf(portfolioAccount);

        assertGe(wethAfter, wethBefore, "WETH balance should not decrease");
        assertGe(xveloAfter, xveloBefore, "USDT0 balance should not decrease");
    }

    // -----------------------------------------------------------------------
    // Test 3: Length mismatch revert
    // -----------------------------------------------------------------------

    function testRevert_claimSuperchainRewards_lengthMismatch() public {
        address[] memory rewardContracts = new address[](2);
        rewardContracts[0] = POOL_FEE_REWARD;
        rewardContracts[1] = POOL_BRIBE_REWARD;

        // Only 1 token array for 2 reward contracts -- mismatch
        address[][] memory tokens = new address[][](1);
        tokens[0] = new address[](1);
        tokens[0][0] = WETH;

        // Call directly on the portfolio account (bypassing multicall for cleaner revert test)
        vm.prank(portfolioAccount);
        vm.expectRevert("Length mismatch");
        SuperchainClaimingFacet(portfolioAccount).claimSuperchainRewards(
            rewardContracts, tokens, TOKEN_ID, SUPERCHAIN_POOL
        );
    }

    // -----------------------------------------------------------------------
    // Test 4: Empty arrays should succeed (no-op)
    // -----------------------------------------------------------------------

    function test_claimSuperchainRewards_emptyArrays() public {
        address[] memory rewardContracts = new address[](0);
        address[][] memory tokens = new address[][](0);

        // Should succeed with no side effects
        vm.startPrank(user, user);
        _multicallClaim(rewardContracts, tokens);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Test 5: Multiple reward contracts in one call (fee + bribe)
    // -----------------------------------------------------------------------

    function test_claimSuperchainRewards_multipleRewardContracts() public {
        // Vote first
        _voteOnSuperchainPool();

        // Advance to next epoch
        uint256 nextEpochStart = ProtocolTimeLibrary.epochNext(block.timestamp);
        vm.warp(nextEpochStart + 3 hours);
        vm.roll(block.number + 1);

        uint256 wethBefore = IERC20(WETH).balanceOf(portfolioAccount);
        uint256 xveloBefore = IERC20(USDT0).balanceOf(portfolioAccount);

        // Claim from both fee and bribe reward contracts in a single call
        address[] memory rewardContracts = new address[](2);
        rewardContracts[0] = POOL_FEE_REWARD;
        rewardContracts[1] = POOL_BRIBE_REWARD;

        address[][] memory tokens = new address[][](2);
        tokens[0] = new address[](2);
        tokens[0][0] = WETH;
        tokens[0][1] = USDT0;
        tokens[1] = new address[](2);
        tokens[1][0] = WETH;
        tokens[1][1] = USDT0;

        vm.startPrank(user, user);
        _multicallClaim(rewardContracts, tokens);
        vm.stopPrank();

        uint256 wethAfter = IERC20(WETH).balanceOf(portfolioAccount);
        uint256 xveloAfter = IERC20(USDT0).balanceOf(portfolioAccount);

        assertGe(wethAfter, wethBefore, "WETH balance should not decrease after multi-claim");
        assertGe(xveloAfter, xveloBefore, "USDT0 balance should not decrease after multi-claim");
    }

    // -----------------------------------------------------------------------
    // Test 6: Verify facet is registered correctly in diamond
    // -----------------------------------------------------------------------

    function test_facetRegistration() public view {
        bytes4 selector = SuperchainClaimingFacet.claimSuperchainRewards.selector;
        address registeredFacet = facetRegistry.getFacetForSelector(selector);
        assertTrue(registeredFacet != address(0), "SuperchainClaimingFacet selector should be registered");
        assertTrue(facetRegistry.isFacetRegistered(registeredFacet), "Facet should be registered");
        assertEq(
            keccak256(bytes(facetRegistry.getFacetName(registeredFacet))),
            keccak256(bytes("SuperchainClaimingFacet")),
            "Facet name should match"
        );
    }

    // -----------------------------------------------------------------------
    // Test 7: Unauthorized caller cannot claim via root contract
    //         (root reward contracts enforce isApprovedOrOwner)
    // -----------------------------------------------------------------------

    function testRevert_claimSuperchainRewards_unauthorizedCaller() public {
        // Vote first
        _voteOnSuperchainPool();

        uint256 nextEpochStart = ProtocolTimeLibrary.epochNext(block.timestamp);
        vm.warp(nextEpochStart + 3 hours);
        vm.roll(block.number + 1);

        address[] memory rewardContracts = new address[](1);
        rewardContracts[0] = POOL_FEE_REWARD;

        address[][] memory tokens = new address[][](1);
        tokens[0] = new address[](2);
        tokens[0][0] = WETH;
        tokens[0][1] = USDT0;

        // Create a separate portfolio that does NOT own the veNFT
        address attacker = address(uint160(uint256(keccak256("attacker"))));
        vm.prank(attacker, attacker);
        address attackerPortfolio = portfolioFactory.createAccount(attacker);

        // Calling getReward from a portfolio that does NOT own the NFT should revert
        // because reward contracts check isApprovedOrOwner(msg.sender, tokenId)
        vm.prank(attackerPortfolio);
        vm.expectRevert();
        SuperchainClaimingFacet(attackerPortfolio).claimSuperchainRewards(
            rewardContracts, tokens, TOKEN_ID, SUPERCHAIN_POOL
        );
    }

    // -----------------------------------------------------------------------
    // Test 8: Reversed length mismatch (more token arrays than reward contracts)
    // -----------------------------------------------------------------------

    function testRevert_claimSuperchainRewards_reverseLengthMismatch() public {
        address[] memory rewardContracts = new address[](1);
        rewardContracts[0] = POOL_FEE_REWARD;

        // 2 token arrays for 1 reward contract
        address[][] memory tokens = new address[][](2);
        tokens[0] = new address[](1);
        tokens[0][0] = WETH;
        tokens[1] = new address[](1);
        tokens[1][0] = USDT0;

        vm.prank(portfolioAccount);
        vm.expectRevert("Length mismatch");
        SuperchainClaimingFacet(portfolioAccount).claimSuperchainRewards(
            rewardContracts, tokens, TOKEN_ID, SUPERCHAIN_POOL
        );
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _voteOnSuperchainPool() internal {
        address[] memory votePools = new address[](1);
        votePools[0] = SUPERCHAIN_POOL;
        uint256[] memory voteWeights = new uint256[](1);
        voteWeights[0] = 100e18;

        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            SuperchainVotingFacet.vote.selector, TOKEN_ID, votePools, voteWeights
        );

        // Must set tx.origin = user because superchain voting triggers cross-chain
        // messaging via Hyperlane, which charges WETH from tx.origin
        vm.startPrank(user, user);
        pm.multicall(calldatas, portfolioFactories);
        vm.stopPrank();
    }

    function _multicallClaim(
        address[] memory rewardContracts,
        address[][] memory tokens
    ) internal {
        address[] memory portfolioFactories = new address[](1);
        portfolioFactories[0] = address(portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(
            SuperchainClaimingFacet.claimSuperchainRewards.selector,
            rewardContracts, tokens, TOKEN_ID, SUPERCHAIN_POOL
        );

        pm.multicall(calldatas, portfolioFactories);
    }
}
