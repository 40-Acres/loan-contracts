// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

// Core accounts
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";

// Config
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../../src/facets/account/config/SwapConfig.sol";

// Facets (types used in helpers)
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../../src/facets/account/lending/BaseLendingFacet.sol";
import {VotingEscrowFacet} from "../../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {BaseMarketplaceFacet} from "../../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {MarketplaceFacet} from "../../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {FortyAcresMarketplaceFacet} from "../../../../src/facets/account/marketplace/FortyAcresMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../../src/facets/marketplace/PortfolioMarketplace.sol";

// Loan + vault
import {Loan} from "../../../../src/Loan.sol";
import {Loan as LoanV2} from "../../../../src/LoanV2.sol";
import {Vault} from "../../../../src/VaultV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Deployment scripts (reused from unit-test pattern)
import {DeployFacets} from "../../../../script/portfolio_account/DeployFacets.s.sol";
import {DeployPortfolioFactoryConfig} from "../../../../script/portfolio_account/DeployPortfolioFactoryConfig.s.sol";

// Interfaces
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title LiveDeploymentSetup
 * @dev Base contract for live-fork E2E tests. Forks Base at latest block and
 *      deploys a fresh factory/config/facet stack under the live PortfolioManager
 *      so every run exercises current branch code instead of whatever facet
 *      bytecode happens to be deployed on mainnet.
 */
abstract contract LiveDeploymentSetup is Test {
    // ─── Live root address kept across runs ──────────────────────────
    address public constant LIVE_PORTFOLIO_MANAGER = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;
    bytes32 public constant TEST_FACTORY_SALT = keccak256(abi.encodePacked("live-e2e-aerodrome-usdc"));

    // Legacy multisig that owns the live legacy Loan proxy. Retained so tests
    // that prank against the on-chain legacy loan (e.g. migration) can reference it.
    address public constant MULTISIG = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;

    // ─── External protocol constants (Base mainnet) ──────────────────
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address public constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address public constant REWARDS_DISTRIBUTOR = 0x227f65131A261548b057215bB1D5Ab2997964C7d;
    address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;

    // ─── Freshly-deployed stack ──────────────────────────────────────
    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;
    PortfolioFactoryConfig public portfolioFactoryConfig;
    LoanConfig public loanConfig;
    VotingConfig public votingConfig;
    SwapConfig public swapConfig;
    PortfolioMarketplace public marketplace;

    // Live wallet factory (already deployed on Base under the live PM with
    // salt keccak256("wallet")). Reused so cross-factory tests that resolve
    // this address via factoryBySalt continue to work.
    bytes32 public constant WALLET_FACTORY_SALT = keccak256(abi.encodePacked("wallet"));
    PortfolioFactory public walletFactory;

    address public constant MARKETPLACE_OWNER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;

    address public loanContract;
    address public vault;
    address public loanConfigAddr;
    address public votingConfigAddr;
    address public liveOwner;

    // ─── Test user state ─────────────────────────────────────────────
    address public user;
    address public portfolioAccount;
    uint256 public tokenId;

    // ─── setUp ───────────────────────────────────────────────────────

    function setUp() public virtual {
        _freshDeploy();
        _ensureLoanConfigDefaults();
        _createTestUserPortfolio();
    }

    /**
     * @dev Fork Base at latest block and deploy a fresh factory/config/facet stack
     *      under the live PortfolioManager. Populates every inherited state var.
     *      Safe to call from overriding `setUp()` implementations.
     */
    function _freshDeploy() internal {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));

        portfolioManager = PortfolioManager(LIVE_PORTFOLIO_MANAGER);
        liveOwner = portfolioManager.owner();

        // Deploy a fresh factory + facet registry under the live manager.
        vm.prank(liveOwner);
        (portfolioFactory, facetRegistry) = portfolioManager.deployFactory(TEST_FACTORY_SALT);

        // Deploy fresh configs owned by liveOwner.
        DeployPortfolioFactoryConfig configDeployer = new DeployPortfolioFactoryConfig();
        (portfolioFactoryConfig, votingConfig, loanConfig, swapConfig) =
            configDeployer.deploy(address(portfolioFactory), liveOwner);

        // Fresh loan proxy (Loan impl, upgraded to LoanV2 after init).
        Loan loanImpl = new Loan();
        loanContract = address(new ERC1967Proxy(address(loanImpl), ""));

        // Fresh vault proxy.
        Vault vaultImpl = new Vault();
        vault = address(new ERC1967Proxy(address(vaultImpl), ""));
        Vault(vault).initialize(USDC, loanContract, "40base-USDC-VAULT", "40base-USDC-VAULT");

        // Init loan and upgrade to LoanV2.
        Loan(loanContract).initialize(vault, USDC);
        LoanV2 loanV2Impl = new LoanV2();
        LoanV2(payable(loanContract)).upgradeToAndCall(address(loanV2Impl), new bytes(0));
        LoanV2(payable(loanContract)).setPortfolioFactory(address(portfolioFactory));

        // Wire factory ↔ config ↔ loan as pmOwner.
        vm.startPrank(liveOwner);
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));
        portfolioFactoryConfig.setLoanContract(loanContract);
        vm.stopPrank();

        // Deploy fresh facets from local source and register them in the new registry.
        DeployFacets facetsDeployer = new DeployFacets();
        facetsDeployer.deploy(
            address(portfolioFactory),
            address(votingConfig),
            VOTING_ESCROW,
            VOTER,
            REWARDS_DISTRIBUTOR,
            address(loanConfig),
            USDC,
            TOKEN_MESSENGER,
            2,
            address(swapConfig),
            loanContract,
            USDC,
            vault
        );

        loanConfigAddr = address(loanConfig);
        votingConfigAddr = address(votingConfig);

        _resolveAndWhitelistMarketplace();
        _deployWalletFactory();

        _validateDiscoveredGraph();
    }

    /**
     * @dev Resolve the freshly-deployed PortfolioMarketplace via the registered
     *      MarketplaceFacet and whitelist USDC so the E2E purchase flow works.
     *      DeployMarketplaceFacets makes its own PortfolioMarketplace with
     *      DEPLOYER_ADDRESS as owner/feeRecipient — prank that to configure.
     */
    function _resolveAndWhitelistMarketplace() internal {
        address marketplaceFacet = facetRegistry.getFacetForSelector(BaseMarketplaceFacet.marketplace.selector);
        require(marketplaceFacet != address(0), "LiveSetup: marketplace facet not registered");
        marketplace = PortfolioMarketplace(MarketplaceFacet(marketplaceFacet)._marketplace());
        require(address(marketplace) != address(0), "LiveSetup: marketplace is zero");

        vm.prank(MARKETPLACE_OWNER);
        marketplace.setAllowedPaymentToken(USDC, true);
    }

    /**
     * @dev Resolve the live wallet factory and repoint its
     *      FortyAcresMarketplaceFacet at our fresh PortfolioMarketplace so
     *      cross-factory buy flows land listings/purchases on the same
     *      marketplace the aerodrome factory uses.
     */
    function _deployWalletFactory() internal {
        address walletAddr = portfolioManager.factoryBySalt(WALLET_FACTORY_SALT);
        require(walletAddr != address(0), "LiveSetup: wallet factory not deployed");
        walletFactory = PortfolioFactory(walletAddr);

        FacetRegistry walletRegistry = walletFactory.facetRegistry();
        address oldFacet = walletRegistry.getFacetForSelector(FortyAcresMarketplaceFacet.buyFortyAcresListing.selector);

        FortyAcresMarketplaceFacet newFacet = new FortyAcresMarketplaceFacet(
            address(walletFactory),
            VOTING_ESCROW,
            address(marketplace)
        );
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = FortyAcresMarketplaceFacet.buyFortyAcresListing.selector;

        vm.startPrank(walletRegistry.owner());
        if (oldFacet == address(0)) {
            walletRegistry.registerFacet(address(newFacet), selectors, "FortyAcresMarketplaceFacet");
        } else {
            walletRegistry.replaceFacet(oldFacet, address(newFacet), selectors, "FortyAcresMarketplaceFacet");
        }
        vm.stopPrank();
    }

    // ─── LoanConfig defaults ─────────────────────────────────────────

    /**
     * @dev Sets sensible LoanConfig defaults so collateral enforcement kicks in.
     *      Tests that want rates at zero (e.g. migration in its first scenario)
     *      can override to a no-op.
     */
    function _ensureLoanConfigDefaults() internal virtual {
        vm.startPrank(liveOwner);
        loanConfig.setRewardsRate(10000);
        loanConfig.setMultiplier(100);
        loanConfig.setLenderPremium(2000);
        loanConfig.setTreasuryFee(500);
        loanConfig.setZeroBalanceFee(100);
        vm.stopPrank();
    }

    // ─── Validation ──────────────────────────────────────────────────

    function _validateDiscoveredGraph() internal view {
        require(address(portfolioManager) != address(0), "LiveSetup: manager is zero");
        require(address(portfolioFactoryConfig) != address(0), "LiveSetup: config is zero");
        require(address(portfolioFactory) != address(0), "LiveSetup: factory is zero");
        require(address(facetRegistry) != address(0), "LiveSetup: registry is zero");
        require(loanContract != address(0), "LiveSetup: loan is zero");
        require(vault != address(0), "LiveSetup: vault is zero");
        require(loanConfigAddr != address(0), "LiveSetup: loanConfig is zero");
        require(votingConfigAddr != address(0), "LiveSetup: votingConfig is zero");
        require(liveOwner != address(0), "LiveSetup: owner is zero");

        require(
            portfolioManager.isRegisteredFactory(address(portfolioFactory)),
            "LiveSetup: factory not registered in manager"
        );
        require(facetRegistry.getVersion() > 0, "LiveSetup: registry version is zero");
    }

    // ─── Test user setup ─────────────────────────────────────────────

    function _createTestUserPortfolio() internal {
        user = address(uint160(uint256(keccak256("live-e2e-test-user"))));

        deal(AERO, user, 100_000e18);
        _fundVault(50_000_000e6);

        portfolioAccount = portfolioFactory.createAccount(user);
        require(portfolioAccount != address(0), "LiveSetup: portfolio not created");

        vm.startPrank(user);
        IERC20(AERO).approve(portfolioAccount, 100_000e18);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(VotingEscrowFacet.createLock.selector, 100_000e18);
        bytes[] memory results = portfolioManager.multicall(calls, factories);
        vm.stopPrank();

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

    function _addCollateral(uint256 _tokenId) internal {
        _singleMulticallAsUser(abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, _tokenId));
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
