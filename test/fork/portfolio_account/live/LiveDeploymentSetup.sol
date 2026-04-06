// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

// Core accounts
import {PortfolioManager} from "../../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../../src/accounts/FacetRegistry.sol";

// Config
import {PortfolioFactoryConfig} from "../../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {ILoanConfig} from "../../../../src/facets/account/config/ILoanConfig.sol";

// Facets
import {ICollateralFacet} from "../../../../src/facets/account/collateral/ICollateralFacet.sol";
import {BaseCollateralFacet} from "../../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BaseLendingFacet} from "../../../../src/facets/account/lending/BaseLendingFacet.sol";
import {VotingEscrowFacet} from "../../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {IMigrationFacet} from "../../../../src/facets/account/migration/IMigrationFacet.sol";
import {MigrationFacet} from "../../../../src/facets/account/migration/MigrationFacet.sol";
import {VotingFacet} from "../../../../src/facets/account/vote/VotingFacet.sol";
import {ClaimingFacet} from "../../../../src/facets/account/claim/ClaimingFacet.sol";
import {LendingFacet} from "../../../../src/facets/account/lending/LendingFacet.sol";
import {CollateralFacet} from "../../../../src/facets/account/collateral/CollateralFacet.sol";
import {MarketplaceFacet} from "../../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {RewardsProcessingFacet} from "../../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {VotingEscrowRewardsProcessingFacet} from "../../../../src/facets/account/rewards_processing/VotingEscrowRewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";

// Loan
import {Loan as LoanV2} from "../../../../src/LoanV2.sol";

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
    address public constant LIVE_PORTFOLIO_MANAGER = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;
    address public constant LIVE_SWAP_CONFIG = 0x3646C436f18f0e2E38E10D1A147f901a96BD4390;
    bytes32 public constant AERODROME_USDC_SALT = keccak256(abi.encodePacked("aerodrome-usdc"));

    // ─── Pending multisig transaction addresses ─────────────────────
    // TODO: Remove this section once the multisig txs are confirmed on-chain
    address public constant MULTISIG = 0xfF16fd3D147220E6CC002a8e4a1f942ac41DBD23;
    // TX1: Loan upgrade + config setup
    address public constant LOAN_PROXY = 0x87f18b377e625b62c708D5f6EA96EC193558EFD0;
    address public constant LOAN_NEW_IMPL = 0xDD9B03C5eB95531448B47cC8466f2B3822c735c3;
    address public constant PORTFOLIO_FACTORY_CONFIG_ADDR = 0xf43Fc8752F138636a003408AcE519976567ed032;
    // TX2: Facet replacements (old → new)
    address public constant NEW_REWARDS_PROCESSING = 0xE3e6d0322aeEC77e9BB7A30d4aD58a22Bbe6Bb48;
    address public constant NEW_REWARDS_CONFIG = 0x68F13a914a2101CFF6e597C382d9D99D23b4B1c5;
    address public constant NEW_CLAIMING = 0xA09fb5F3e27cD93BC0fd817540915115d3B65fe7;
    address public constant NEW_LENDING = 0x2B5CB59Bb7aA502CE92a5a8C7742cE3FdDd032AD;
    address public constant NEW_MARKETPLACE = 0xc62B46e5001c0A2ef3d90f0b39fC285BCC00e98c;
    address public constant NEW_VOTING = 0xd6d68f4ECaCc6e26beC94Bc9f6510b80248C3AAe;
    address public constant NEW_VOTING_ESCROW = 0xAb6F4529a2f8641405607C4DAf3F3bFa6bF9B99c;
    address public constant NEW_COLLATERAL = 0x95f6926932A188498a96bb0a7b31159999D7784B;
    address public constant NEW_MIGRATION = 0x0008E74309D117C22474afda2807Eb3b42402568;

    // ─── External protocol constants (same as BaseDeploymentSetup) ───
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address public constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;

    // ─── Auto-discovered contracts ───────────────────────────────────
    PortfolioManager public portfolioManager;
    PortfolioFactoryConfig public portfolioFactoryConfig;
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

        // 3. Discover factory from PortfolioManager by salt
        address factoryAddr = portfolioManager.factoryBySalt(AERODROME_USDC_SALT);
        require(factoryAddr != address(0), "LiveSetup: aerodrome-usdc factory not deployed");
        portfolioFactory = PortfolioFactory(factoryAddr);

        // 4. Simulate pending multisig tx (remove once confirmed on-chain)
        _simulatePendingMultisigTx();

        // 5. Discover config from factory (canonical source of truth)
        portfolioFactoryConfig = portfolioFactory.portfolioFactoryConfig();

        // 6. Auto-discover from PortfolioFactoryConfig
        loanContract = portfolioFactoryConfig.getLoanContract();
        loanConfigAddr = address(portfolioFactoryConfig.getLoanConfig());
        votingConfigAddr = portfolioFactoryConfig.getVoteConfig();
        vault = portfolioFactoryConfig.getVault();

        // 7. Set LoanConfig defaults if not yet configured
        _ensureLoanConfigDefaults();

        // 8. Discover FacetRegistry from factory
        facetRegistry = portfolioFactory.facetRegistry();

        // 9. Discover live owner for pranking owner-only operations
        liveOwner = portfolioFactoryConfig.owner();

        // 10. Validate the discovered graph (skip if not yet deployed)
        if (!portfolioManager.isRegisteredFactory(address(portfolioFactory))) {
            vm.skip(true);
        }
        _validateDiscoveredGraph();

        // 11. Create deterministic test user and portfolio
        user = address(uint160(uint256(keccak256("live-e2e-test-user"))));
        _createTestUserPortfolio();
    }


    function _simulatePendingMultisigTx() internal {
        // Simulate marketplace facet upgrade to add isListingPurchasable selector
        FacetRegistry _facetRegistry = portfolioFactory.facetRegistry();
        address existingMarketplace = _facetRegistry.getFacetForSelector(BaseMarketplaceFacet.receiveSaleProceeds.selector);
        if (existingMarketplace != address(0)) {
            // Check if isListingPurchasable is already registered
            address isListingFacet = _facetRegistry.getFacetForSelector(BaseMarketplaceFacet.isListingPurchasable.selector);
            if (isListingFacet == address(0)) {
                address registryOwner = _facetRegistry.owner();
                vm.startPrank(registryOwner);
                _facetRegistry.removeFacet(existingMarketplace);

                bytes4[] memory selectors = new bytes4[](8);
                selectors[0] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
                selectors[1] = BaseMarketplaceFacet.makeListing.selector;
                selectors[2] = BaseMarketplaceFacet.cancelListing.selector;
                selectors[3] = BaseMarketplaceFacet.marketplace.selector;
                selectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
                selectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
                selectors[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
                selectors[7] = BaseMarketplaceFacet.isListingPurchasable.selector;

                _facetRegistry.registerFacet(existingMarketplace, selectors, "MarketplaceFacet");
                vm.stopPrank();
            }
        }
    }

    // ─── LoanConfig defaults ─────────────────────────────────────────
    // TODO: Remove once LoanConfig values are set on-chain via multisig.

    function _ensureLoanConfigDefaults() internal {
        ILoanConfig loanConfig = ILoanConfig(loanConfigAddr);
        if (loanConfig.getRewardsRate() == 0) {
            revert();
        }
        if (loanConfig.getMultiplier() == 0) {
            revert();
        }
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
        deal(AERO, user, 100_000e18);

        // Ensure vault has enough USDC to stay under 80% utilization
        _fundVault(50_000_000e6);

        // Step 1: Create portfolio account (permissionless call)
        portfolioAccount = portfolioFactory.createAccount(user);
        require(portfolioAccount != address(0), "LiveSetup: portfolio not created");

        // Step 2: Approve AERO to the real portfolio address, then createLock via multicall
        vm.startPrank(user);
        IERC20(AERO).approve(portfolioAccount, 100_000e18);

        address[] memory factories = new address[](1);
        factories[0] = address(portfolioFactory);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(VotingEscrowFacet.createLock.selector, 100_000e18);
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
