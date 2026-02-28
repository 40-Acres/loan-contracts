// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

// Core accounts
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";

// Config
import {PortfolioAccountConfig} from "../../../../src/facets/account/config/PortfolioAccountConfig.sol";

// Facets
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../../src/facets/account/lending/BaseLendingFacet.sol";
import {VotingEscrowFacet} from "../../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";

// Interfaces
import {IVotingEscrow} from "../../../../src/interfaces/IVotingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LiveDeploymentSetup
 * @dev Base contract for live deployment E2E tests. Forks Base at latest block
 *      and auto-discovers all contracts from 3 root addresses.
 *
 *      Unlike BaseForkSetup which deploys fresh contracts on a fork, this setup
 *      points to the actual live deployment to catch issues like misconfigured
 *      proxies, missing facet registrations, or broken config linkages.
 */
abstract contract LiveDeploymentSetup is Test {
    // ─── Root addresses (only hardcoded constants) ───────────────────
    address public constant LIVE_PORTFOLIO_MANAGER = 0x427D890e5794A8B3AB3b9aEe0B3481F5CBCc09C5;
    address public constant LIVE_PORTFOLIO_ACCOUNT_CONFIG = 0x400C710cbEadc5bb8b7132B3061fA1b6d6f80Dd8;
    address public constant LIVE_SWAP_CONFIG = 0x3646C436f18f0e2E38E10D1A147f901a96BD4390;

    // ─── External protocol constants (same as BaseDeploymentSetup) ───
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address public constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;

    // ─── Auto-discovered contracts ───────────────────────────────────
    PortfolioManager public portfolioManager;
    PortfolioAccountConfig public portfolioAccountConfig;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;

    address public loanContract;
    address public vault;
    address public loanConfigAddr;
    address public votingConfigAddr;
    address public liveOwner;

    // ─── Test user state ─────────────────────────────────────────────
    address public user;
    address public portfolioAccount;
    uint256 public tokenId; // veNFT tokenId created during setUp

    // ─── setUp ───────────────────────────────────────────────────────

    function setUp() public virtual {
        // 1. Fork Base at latest block
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));

        // 2. Bind root contracts
        portfolioManager = PortfolioManager(LIVE_PORTFOLIO_MANAGER);
        portfolioAccountConfig = PortfolioAccountConfig(LIVE_PORTFOLIO_ACCOUNT_CONFIG);

        // 3. Auto-discover from PortfolioAccountConfig
        loanContract = portfolioAccountConfig.getLoanContract();
        loanConfigAddr = address(portfolioAccountConfig.getLoanConfig());
        votingConfigAddr = portfolioAccountConfig.getVoteConfig();
        vault = portfolioAccountConfig.getVault();
        address discoveredFactory = portfolioAccountConfig.getPortfolioFactory();
        portfolioFactory = PortfolioFactory(discoveredFactory);

        // 4. Discover FacetRegistry from factory
        facetRegistry = portfolioFactory.facetRegistry();

        // 5. Discover live owner for pranking owner-only operations
        liveOwner = portfolioAccountConfig.owner();

        // 6. Validate the discovered graph
        _validateDiscoveredGraph();

        // 7. Create deterministic test user and portfolio
        user = address(uint160(uint256(keccak256("live-e2e-test-user"))));
        _createTestUserPortfolio();
    }

    // ─── Validation ──────────────────────────────────────────────────

    function _validateDiscoveredGraph() internal view {
        require(address(portfolioManager) != address(0), "LiveSetup: manager is zero");
        require(address(portfolioAccountConfig) != address(0), "LiveSetup: config is zero");
        require(address(portfolioFactory) != address(0), "LiveSetup: factory is zero");
        require(address(facetRegistry) != address(0), "LiveSetup: registry is zero");
        require(loanContract != address(0), "LiveSetup: loan is zero");
        require(vault != address(0), "LiveSetup: vault is zero");
        require(loanConfigAddr != address(0), "LiveSetup: loanConfig is zero");
        require(votingConfigAddr != address(0), "LiveSetup: votingConfig is zero");
        require(liveOwner != address(0), "LiveSetup: owner is zero");

        // Factory registered in manager
        require(
            portfolioManager.isRegisteredFactory(address(portfolioFactory)),
            "LiveSetup: factory not registered in manager"
        );

        // Registry has facets registered
        require(facetRegistry.getVersion() > 0, "LiveSetup: registry version is zero");
    }

    // ─── Test user setup ─────────────────────────────────────────────

    function _createTestUserPortfolio() internal {
        // CREATE2 prediction is unreliable against live deployments (bytecode may differ
        // from local compilation). Instead, create the account first, then approve.

        // Fund user with AERO for veNFT creation in tests
        deal(AERO, user, 10_000e18);

        // Ensure vault has USDC for borrowing
        _fundVault(1_000_000e6);

        // Step 1: Create portfolio account (permissionless call)
        portfolioAccount = portfolioFactory.createAccount(user);
        require(portfolioAccount != address(0), "LiveSetup: portfolio not created");

        // Step 2: Approve AERO to the real portfolio address, then createLock via multicall
        vm.startPrank(user);
        IERC20(AERO).approve(portfolioAccount, 1000e18);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(VotingEscrowFacet.createLock.selector, 1000e18);
        bytes[] memory results = portfolioManager.multicall(calls, factories);
        vm.stopPrank();

        // Decode tokenId from createLock return value
        tokenId = abi.decode(results[0], (uint256));
    }

    // ─── Multicall helpers ───────────────────────────────────────────

    function _multicallAsUser(bytes[] memory calldatas) internal returns (bytes[] memory) {
        address[] memory factories = new address[](calldatas.length);
        for (uint256 i = 0; i < calldatas.length; i++) {
            factories[i] = address(portfolioFactory);
        }
        vm.prank(user);
        return portfolioManager.multicall(calldatas, factories);
    }

    function _singleMulticallAsUser(bytes memory data) internal returns (bytes[] memory) {
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = data;
        return _multicallAsUser(calldatas);
    }

    function _addCollateral(uint256 tokenId) internal {
        _singleMulticallAsUser(abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, tokenId));
    }

    function _borrow(uint256 amount) internal {
        _singleMulticallAsUser(abi.encodeWithSelector(BaseLendingFacet.borrow.selector, amount));
    }

    // ─── Funding helpers ─────────────────────────────────────────────

    function _fundVault(uint256 amount) internal {
        uint256 existing = IERC20(USDC).balanceOf(vault);
        if (existing < amount) {
            deal(USDC, vault, amount);
        }
    }

    function _createVeNFTForUser(address _user, uint256 lockAmount) internal returns (uint256 _tokenId) {
        address portfolio = portfolioFactory.portfolioOf(_user);
        require(portfolio != address(0), "LiveSetup: user has no portfolio");

        deal(AERO, _user, lockAmount);
        vm.startPrank(_user);
        IERC20(AERO).approve(portfolio, lockAmount);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(VotingEscrowFacet.createLock.selector, lockAmount);
        bytes[] memory results = portfolioManager.multicall(calls, factories);
        vm.stopPrank();

        _tokenId = abi.decode(results[0], (uint256));
    }
}
