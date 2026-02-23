// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

// Core accounts
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {FortyAcresPortfolioAccount} from "../../../src/accounts/FortyAcresPortfolioAccount.sol";

// Config
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";

// Facets
import {ClaimingFacet} from "../../../src/facets/account/claim/ClaimingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";
import {VotingEscrowFacet} from "../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {MigrationFacet} from "../../../src/facets/account/migration/MigrationFacet.sol";
import {IMigrationFacet} from "../../../src/facets/account/migration/IMigrationFacet.sol";
import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../src/facets/marketplace/PortfolioMarketplace.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";

// Loan / Vault
import {Loan} from "../../../src/Loan.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";
import {Vault} from "../../../src/VaultV2.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";

// Interfaces
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../../src/interfaces/IVoter.sol";
import {IRewardsDistributor} from "../../../src/interfaces/IRewardsDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title BaseDeploymentSetup
 * @dev Abstract base contract that mirrors AerodromeRootDeploy._deploy() logic
 *      inside setUp(). Deploys all contracts locally (no fork required).
 *
 *      External address constants from DeployAerodrome.s.sol are retained
 *      for constructor args but no on-chain interactions occur here.
 *      Tests that need real on-chain state should extend BaseForkSetup.
 */
abstract contract BaseDeploymentSetup is Test {
    // ─── External addresses (Base chain) ─────────────────────────────
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address public constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address public constant REWARDS_DISTRIBUTOR = 0x227f65131A261548b057215bB1D5Ab2997964C7d;
    address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address public constant DEPLOYER = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

    // ─── Core contracts ──────────────────────────────────────────────
    PortfolioManager public portfolioManager;
    PortfolioFactory public portfolioFactory;
    FacetRegistry public facetRegistry;

    // ─── Config contracts ────────────────────────────────────────────
    PortfolioAccountConfig public portfolioAccountConfig;
    VotingConfig public votingConfig;
    LoanConfig public loanConfig;
    SwapConfig public swapConfig;

    // ─── Loan / Vault ────────────────────────────────────────────────
    address public loanContract;
    Vault public vault;

    // ─── Facet instances ─────────────────────────────────────────────
    ClaimingFacet public claimingFacet;
    CollateralFacet public collateralFacet;
    LendingFacet public lendingFacet;
    VotingFacet public votingFacet;
    VotingEscrowFacet public votingEscrowFacet;
    MigrationFacet public migrationFacet;
    MarketplaceFacet public marketplaceFacet;
    RewardsProcessingFacet public rewardsProcessingFacet;
    PortfolioMarketplace public portfolioMarketplace;

    // ─── User state ──────────────────────────────────────────────────
    address public user = address(0x40ac2e);
    address public authorizedCaller = address(0xaaaaa);
    address public portfolioAccount;
    uint256 public tokenId = 84297;

    // ─── setUp ───────────────────────────────────────────────────────

    function setUp() public virtual {
        _setupExternalMocks();
        vm.startPrank(DEPLOYER);
        _deployCore();
        _deployConfigs();
        _deployLoanAndVault();
        _deployAndRegisterFacets();
        _setLoanConfigDefaults();
        vm.stopPrank();

        _createUserPortfolio();
    }

    /// @dev Mock external contract calls needed during deployment.
    ///      Override to no-op in BaseForkSetup where real contracts exist.
    function _setupExternalMocks() internal virtual {
        vm.mockCall(USDC, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.mockCall(USDC, abi.encodeWithSignature("approve(address,uint256)"), abi.encode(true));
    }

    // ─── Internal deployment steps ───────────────────────────────────

    /// @dev Step 1: PortfolioManager → deployFactory (mirrors deploy script)
    function _deployCore() internal {
        portfolioManager = new PortfolioManager(DEPLOYER);
        (PortfolioFactory factory_, FacetRegistry registry_) = portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("aerodrome-usdc")))
        );
        portfolioFactory = factory_;
        facetRegistry = registry_;
    }

    /// @dev Step 2: Config contracts via ERC1967Proxy with atomic init
    function _deployConfigs() internal {
        // PortfolioAccountConfig
        PortfolioAccountConfig configImpl = new PortfolioAccountConfig();
        portfolioAccountConfig = PortfolioAccountConfig(
            address(new ERC1967Proxy(
                address(configImpl),
                abi.encodeCall(PortfolioAccountConfig.initialize, (DEPLOYER))
            ))
        );

        // VotingConfig
        VotingConfig votingConfigImpl = new VotingConfig();
        votingConfig = VotingConfig(
            address(new ERC1967Proxy(
                address(votingConfigImpl),
                abi.encodeCall(VotingConfig.initialize, (DEPLOYER))
            ))
        );

        // LoanConfig
        LoanConfig loanConfigImpl = new LoanConfig();
        loanConfig = LoanConfig(
            address(new ERC1967Proxy(
                address(loanConfigImpl),
                abi.encodeCall(LoanConfig.initialize, (DEPLOYER))
            ))
        );

        // SwapConfig
        SwapConfig swapConfigImpl = new SwapConfig();
        swapConfig = SwapConfig(
            address(new ERC1967Proxy(
                address(swapConfigImpl),
                abi.encodeCall(SwapConfig.initialize, (DEPLOYER))
            ))
        );

        // Link configs (mirrors deploy script)
        portfolioAccountConfig.setVoteConfig(address(votingConfig));
        portfolioAccountConfig.setLoanConfig(address(loanConfig));
    }

    /// @dev Step 3: Loan (V1 proxy → initialize → upgrade V2) + Vault
    function _deployLoanAndVault() internal {
        // Deploy Loan V1 proxy
        Loan loanImpl = new Loan();
        ERC1967Proxy loanProxy = new ERC1967Proxy(address(loanImpl), "");
        loanContract = address(loanProxy);

        // Deploy Vault proxy
        Vault vaultImpl = new Vault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), "");
        vault = Vault(address(vaultProxy));

        // Initialize vault
        vault.initialize(USDC, loanContract, "40base-USDC-VAULT", "40base-USDC-VAULT");

        // Initialize loan (sets owner to DEPLOYER)
        Loan(loanContract).initialize(address(vault), USDC);

        // Upgrade to LoanV2
        LoanV2 loanV2Impl = new LoanV2();
        LoanV2(loanContract).upgradeToAndCall(address(loanV2Impl), new bytes(0));

        // Set portfolio factory on loan and config
        LoanV2(loanContract).setPortfolioFactory(address(portfolioFactory));
        portfolioAccountConfig.setPortfolioFactory(address(portfolioFactory));
        portfolioAccountConfig.setLoanContract(loanContract);
    }

    /// @dev Step 4: Deploy and register all 8 facets with exact selector arrays from deploy script
    function _deployAndRegisterFacets() internal {
        // ── 1. ClaimingFacet (3 selectors) ──
        claimingFacet = new ClaimingFacet(
            address(portfolioFactory), address(portfolioAccountConfig),
            VOTING_ESCROW, VOTER, REWARDS_DISTRIBUTOR,
            address(loanConfig), address(swapConfig), address(vault)
        );
        bytes4[] memory claimingSel = new bytes4[](3);
        claimingSel[0] = ClaimingFacet.claimFees.selector;
        claimingSel[1] = ClaimingFacet.claimRebase.selector;
        claimingSel[2] = ClaimingFacet.claimLaunchpadToken.selector;
        facetRegistry.registerFacet(address(claimingFacet), claimingSel, "ClaimingFacet");

        // ── 2. CollateralFacet (11 selectors) ──
        collateralFacet = new CollateralFacet(
            address(portfolioFactory), address(portfolioAccountConfig), VOTING_ESCROW
        );
        bytes4[] memory collateralSel = new bytes4[](11);
        collateralSel[0] = BaseCollateralFacet.addCollateral.selector;
        collateralSel[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        collateralSel[2] = BaseCollateralFacet.getTotalDebt.selector;
        collateralSel[3] = BaseCollateralFacet.getUnpaidFees.selector;
        collateralSel[4] = BaseCollateralFacet.getMaxLoan.selector;
        collateralSel[5] = BaseCollateralFacet.getOriginTimestamp.selector;
        collateralSel[6] = BaseCollateralFacet.removeCollateral.selector;
        collateralSel[7] = BaseCollateralFacet.getCollateralToken.selector;
        collateralSel[8] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        collateralSel[9] = BaseCollateralFacet.getLockedCollateral.selector;
        collateralSel[10] = BaseCollateralFacet.removeCollateralTo.selector;
        facetRegistry.registerFacet(address(collateralFacet), collateralSel, "CollateralFacet");

        // ── 3. LendingFacet (5 selectors) ──
        lendingFacet = new LendingFacet(
            address(portfolioFactory), address(portfolioAccountConfig), USDC
        );
        bytes4[] memory lendingSel = new bytes4[](5);
        lendingSel[0] = BaseLendingFacet.borrow.selector;
        lendingSel[1] = BaseLendingFacet.pay.selector;
        lendingSel[2] = BaseLendingFacet.setTopUp.selector;
        lendingSel[3] = BaseLendingFacet.topUp.selector;
        lendingSel[4] = BaseLendingFacet.borrowTo.selector;
        facetRegistry.registerFacet(address(lendingFacet), lendingSel, "LendingFacet");

        // ── 4. VotingFacet (5 selectors) ──
        votingFacet = new VotingFacet(
            address(portfolioFactory), address(portfolioAccountConfig),
            address(votingConfig), VOTING_ESCROW, VOTER
        );
        bytes4[] memory votingSel = new bytes4[](5);
        votingSel[0] = VotingFacet.vote.selector;
        votingSel[1] = VotingFacet.voteForLaunchpadToken.selector;
        votingSel[2] = VotingFacet.setVotingMode.selector;
        votingSel[3] = VotingFacet.isManualVoting.selector;
        votingSel[4] = VotingFacet.defaultVote.selector;
        facetRegistry.registerFacet(address(votingFacet), votingSel, "VotingFacet");

        // ── 5. VotingEscrowFacet (4 selectors) ──
        votingEscrowFacet = new VotingEscrowFacet(
            address(portfolioFactory), address(portfolioAccountConfig),
            VOTING_ESCROW, VOTER
        );
        bytes4[] memory votingEscrowSel = new bytes4[](4);
        votingEscrowSel[0] = VotingEscrowFacet.increaseLock.selector;
        votingEscrowSel[1] = VotingEscrowFacet.createLock.selector;
        votingEscrowSel[2] = VotingEscrowFacet.merge.selector;
        votingEscrowSel[3] = VotingEscrowFacet.onERC721Received.selector;
        facetRegistry.registerFacet(address(votingEscrowFacet), votingEscrowSel, "VotingEscrowFacet");

        // ── 6. MigrationFacet (1 selector) ──
        migrationFacet = new MigrationFacet(
            address(portfolioFactory), address(portfolioAccountConfig), VOTING_ESCROW
        );
        bytes4[] memory migrationSel = new bytes4[](1);
        migrationSel[0] = IMigrationFacet.migrate.selector;
        facetRegistry.registerFacet(address(migrationFacet), migrationSel, "MigrationFacet");

        // ── 7. MarketplaceFacet (6 selectors) ──
        portfolioMarketplace = new PortfolioMarketplace(
            address(portfolioManager), VOTING_ESCROW, 100, DEPLOYER
        );
        marketplaceFacet = new MarketplaceFacet(
            address(portfolioFactory), address(portfolioAccountConfig),
            VOTING_ESCROW, address(portfolioMarketplace)
        );
        bytes4[] memory marketplaceSel = new bytes4[](6);
        marketplaceSel[0] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        marketplaceSel[1] = BaseMarketplaceFacet.makeListing.selector;
        marketplaceSel[2] = BaseMarketplaceFacet.cancelListing.selector;
        marketplaceSel[3] = BaseMarketplaceFacet.marketplace.selector;
        marketplaceSel[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        marketplaceSel[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        facetRegistry.registerFacet(address(marketplaceFacet), marketplaceSel, "MarketplaceFacet");

        // ── 8. RewardsProcessingFacet (10 selectors) ──
        rewardsProcessingFacet = new RewardsProcessingFacet(
            address(portfolioFactory), address(portfolioAccountConfig),
            address(swapConfig), VOTING_ESCROW, address(vault)
        );
        bytes4[] memory rewardsSel = new bytes4[](12);
        rewardsSel[0] = RewardsProcessingFacet.processRewards.selector;
        rewardsSel[1] = RewardsProcessingFacet.setRewardsToken.selector;
        rewardsSel[2] = RewardsProcessingFacet.getRewardsToken.selector;
        rewardsSel[3] = RewardsProcessingFacet.setRecipient.selector;
        rewardsSel[4] = RewardsProcessingFacet.swapToRewardsToken.selector;
        rewardsSel[5] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        rewardsSel[6] = RewardsProcessingFacet.calculateRoutes.selector;
        rewardsSel[7] = RewardsProcessingFacet.setZeroBalanceDistribution.selector;
        rewardsSel[8] = RewardsProcessingFacet.getZeroBalanceDistribution.selector;
        rewardsSel[9] = RewardsProcessingFacet.setActiveBalanceDistribution.selector;
        rewardsSel[10] = RewardsProcessingFacet.getActiveBalanceDistribution.selector;
        rewardsSel[11] = RewardsProcessingFacet.clearActiveBalanceDistribution.selector;
        facetRegistry.registerFacet(address(rewardsProcessingFacet), rewardsSel, "RewardsProcessingFacet");
    }

    /// @dev Step 5: Set LoanConfig defaults and authorized caller (matches deploy-time values)
    function _setLoanConfigDefaults() internal {
        loanConfig.setRewardsRate(10000);
        loanConfig.setMultiplier(100);
        loanConfig.setLenderPremium(2000);
        loanConfig.setTreasuryFee(500);
        loanConfig.setZeroBalanceFee(100);
        portfolioManager.setAuthorizedCaller(authorizedCaller, true);
    }

    /// @dev Step 6: Create user portfolio (override in BaseForkSetup to transfer veNFT)
    function _createUserPortfolio() internal virtual {
        portfolioAccount = portfolioFactory.createAccount(user);
    }

    // ─── Multicall helpers ───────────────────────────────────────────

    /// @dev Execute multiple calls through portfolioManager.multicall as `user`
    function _multicallAsUser(bytes[] memory calldatas) internal returns (bytes[] memory) {
        address[] memory factories = new address[](calldatas.length);
        for (uint256 i = 0; i < calldatas.length; i++) {
            factories[i] = address(portfolioFactory);
        }
        vm.prank(user);
        return portfolioManager.multicall(calldatas, factories);
    }

    /// @dev Execute a single call through portfolioManager.multicall as `user`
    function _singleMulticallAsUser(bytes memory data) internal returns (bytes[] memory) {
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = data;
        return _multicallAsUser(calldatas);
    }

    /// @dev Add collateral via multicall
    function _addCollateral(uint256 _tokenId) internal {
        _singleMulticallAsUser(abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, _tokenId));
    }

    /// @dev Borrow via multicall
    function _borrow(uint256 amount) internal {
        _singleMulticallAsUser(abi.encodeWithSelector(BaseLendingFacet.borrow.selector, amount));
    }

    /// @dev Fund the vault with USDC
    function _fundVault(uint256 amount) internal {
        deal(USDC, address(vault), amount);
    }
}
