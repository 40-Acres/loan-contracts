// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";

// Core accounts
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";

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

// Mocks
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockVotingEscrow} from "../../mocks/MockVotingEscrow.sol";
import {MockVoter} from "../../mocks/MockVoter.sol";
import {MockRewardsDistributor} from "../../mocks/MockRewardsDistributor.sol";

/**
 * @title LocalSetup
 * @dev Mirrors Setup.sol variable names but deploys everything locally with mocks.
 *      No fork required — uses MockVotingEscrow, MockVoter, MockRewardsDistributor.
 */
contract LocalSetup is Test {
    // ── Same variable names as Setup.sol ────────────────────────────────
    ClaimingFacet public _claimingFacet;
    PortfolioFactory public _portfolioFactory;

    // config addresses
    LoanConfig public _loanConfig;
    VotingConfig public _votingConfig;
    PortfolioAccountConfig public _portfolioAccountConfig;
    PortfolioManager public _portfolioManager;
    SwapConfig public _swapConfig;
    FacetRegistry public _facetRegistry;

    // These are cast to interface types for compatibility with test code
    IVotingEscrow public _votingEscrow;
    IVoter public _voter;
    IRewardsDistributor public _rewardsDistributor;
    IERC20 public _asset; // USDC
    IERC20 public _aero;  // AERO
    IVotingEscrow public _ve;

    address public _tokenMessenger = address(0xdead01);
    address FORTY_ACRES_DEPLOYER = address(0x40FecA5f7156030b78200450852792ea93f7c6cd);
    address public _aeroFactory = address(0);
    address public _usdc;
    address public _authorizedCaller = address(0xaaaaa);
    address public _loanContract;
    address public _vault;

    address public _user = address(0x40ac2e);
    address public _portfolioAccount;
    uint256 public _tokenId;
    address public _owner = FORTY_ACRES_DEPLOYER;

    // ── Additional state for local mocks ──────────────────────────────
    MockVotingEscrow public _mockVe;
    MockVoter public _mockVoter;
    MockRewardsDistributor public _mockRewardsDistributor;
    MockERC20 public _mockUsdc;
    MockERC20 public _mockAero;

    // Second veNFT (pre-created for multi-token tests)
    uint256 public _tokenId2;
    address public _tokenId2Owner = address(0xBEEF02);

    // Facet instances (for tests that need direct references)
    PortfolioMarketplace public _portfolioMarketplace;

    function setUp() public virtual {
        // Warp to a realistic timestamp (ProtocolTimeLibrary expects reasonable timestamps)
        vm.warp(1700000000); // Nov 2023 — well within safe range
        vm.roll(100);

        _deployMocks();
        _deployCore();
        _deployConfigs();
        _deployLoanAndVault();
        _deployAndRegisterFacets();
        _setLoanConfigDefaults();
        _createUserPortfolio();
        _setupVeNFTs();
    }

    // ── Step 1: Deploy mock external contracts ────────────────────────
    function _deployMocks() internal {
        _mockUsdc = new MockERC20("USD Coin", "USDC", 6);
        _mockAero = new MockERC20("Aerodrome", "AERO", 18);
        _mockVe = new MockVotingEscrow(address(_mockAero));
        _mockVoter = new MockVoter();
        _mockRewardsDistributor = new MockRewardsDistributor();

        // Cast to interface types (matching Setup.sol variable names)
        _usdc = address(_mockUsdc);
        _asset = IERC20(_usdc);
        _aero = IERC20(address(_mockAero));
        _ve = IVotingEscrow(address(_mockVe));
        _votingEscrow = _ve;
        _voter = IVoter(address(_mockVoter));
        _rewardsDistributor = IRewardsDistributor(address(_mockRewardsDistributor));
    }

    // ── Step 2: PortfolioManager → deployFactory ──────────────────────
    function _deployCore() internal {
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _portfolioManager = new PortfolioManager(FORTY_ACRES_DEPLOYER);
        (PortfolioFactory factory_, FacetRegistry registry_) = _portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("aerodrome-usdc")))
        );
        _portfolioFactory = factory_;
        _facetRegistry = registry_;
        vm.stopPrank();
    }

    // ── Step 3: Config contracts via ERC1967Proxy ─────────────────────
    function _deployConfigs() internal {
        vm.startPrank(FORTY_ACRES_DEPLOYER);

        PortfolioAccountConfig configImpl = new PortfolioAccountConfig();
        _portfolioAccountConfig = PortfolioAccountConfig(
            address(new ERC1967Proxy(
                address(configImpl),
                abi.encodeCall(PortfolioAccountConfig.initialize, (FORTY_ACRES_DEPLOYER))
            ))
        );

        VotingConfig votingConfigImpl = new VotingConfig();
        _votingConfig = VotingConfig(
            address(new ERC1967Proxy(
                address(votingConfigImpl),
                abi.encodeCall(VotingConfig.initialize, (FORTY_ACRES_DEPLOYER))
            ))
        );

        LoanConfig loanConfigImpl = new LoanConfig();
        _loanConfig = LoanConfig(
            address(new ERC1967Proxy(
                address(loanConfigImpl),
                abi.encodeCall(LoanConfig.initialize, (FORTY_ACRES_DEPLOYER))
            ))
        );

        SwapConfig swapConfigImpl = new SwapConfig();
        _swapConfig = SwapConfig(
            address(new ERC1967Proxy(
                address(swapConfigImpl),
                abi.encodeCall(SwapConfig.initialize, (FORTY_ACRES_DEPLOYER))
            ))
        );

        _portfolioAccountConfig.setVoteConfig(address(_votingConfig));
        _portfolioAccountConfig.setLoanConfig(address(_loanConfig));

        vm.stopPrank();
    }

    // ── Step 4: Loan (V1 proxy → initialize → upgrade V2) + Vault ─────
    function _deployLoanAndVault() internal {
        vm.startPrank(FORTY_ACRES_DEPLOYER);

        Loan loanImpl = new Loan();
        ERC1967Proxy loanProxy = new ERC1967Proxy(address(loanImpl), "");
        _loanContract = address(loanProxy);

        Vault vaultImpl = new Vault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), "");
        Vault vault = Vault(address(vaultProxy));

        vault.initialize(_usdc, _loanContract, "40base-USDC-VAULT", "40base-USDC-VAULT");
        Loan(_loanContract).initialize(address(vault), _usdc);

        LoanV2 loanV2Impl = new LoanV2();
        LoanV2(_loanContract).upgradeToAndCall(address(loanV2Impl), new bytes(0));
        LoanV2(_loanContract).setPortfolioFactory(address(_portfolioFactory));

        _vault = address(vault);

        _portfolioAccountConfig.setPortfolioFactory(address(_portfolioFactory));
        _portfolioAccountConfig.setLoanContract(_loanContract);

        vm.stopPrank();
    }

    // ── Step 5: Deploy and register all facets ────────────────────────
    function _deployAndRegisterFacets() internal {
        vm.startPrank(FORTY_ACRES_DEPLOYER);

        // ── 1. ClaimingFacet (3 selectors) ──
        _claimingFacet = new ClaimingFacet(
            address(_portfolioFactory), address(_portfolioAccountConfig),
            address(_ve), address(_voter), address(_rewardsDistributor),
            address(_loanConfig), address(_swapConfig), _vault
        );
        bytes4[] memory claimingSel = new bytes4[](3);
        claimingSel[0] = ClaimingFacet.claimFees.selector;
        claimingSel[1] = ClaimingFacet.claimRebase.selector;
        claimingSel[2] = ClaimingFacet.claimLaunchpadToken.selector;
        _facetRegistry.registerFacet(address(_claimingFacet), claimingSel, "ClaimingFacet");

        // ── 2. CollateralFacet (11 selectors) ──
        CollateralFacet collateralFacet = new CollateralFacet(
            address(_portfolioFactory), address(_portfolioAccountConfig), address(_ve)
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
        _facetRegistry.registerFacet(address(collateralFacet), collateralSel, "CollateralFacet");

        // ── 3. LendingFacet (5 selectors) ──
        LendingFacet lendingFacet = new LendingFacet(
            address(_portfolioFactory), address(_portfolioAccountConfig), _usdc
        );
        bytes4[] memory lendingSel = new bytes4[](5);
        lendingSel[0] = BaseLendingFacet.borrow.selector;
        lendingSel[1] = BaseLendingFacet.pay.selector;
        lendingSel[2] = BaseLendingFacet.setTopUp.selector;
        lendingSel[3] = BaseLendingFacet.topUp.selector;
        lendingSel[4] = BaseLendingFacet.borrowTo.selector;
        _facetRegistry.registerFacet(address(lendingFacet), lendingSel, "LendingFacet");

        // ── 4. VotingFacet (5 selectors) ──
        VotingFacet votingFacet = new VotingFacet(
            address(_portfolioFactory), address(_portfolioAccountConfig),
            address(_votingConfig), address(_ve), address(_voter)
        );
        bytes4[] memory votingSel = new bytes4[](5);
        votingSel[0] = VotingFacet.vote.selector;
        votingSel[1] = VotingFacet.voteForLaunchpadToken.selector;
        votingSel[2] = VotingFacet.setVotingMode.selector;
        votingSel[3] = VotingFacet.isManualVoting.selector;
        votingSel[4] = VotingFacet.defaultVote.selector;
        _facetRegistry.registerFacet(address(votingFacet), votingSel, "VotingFacet");

        // ── 5. VotingEscrowFacet (4 selectors) ──
        VotingEscrowFacet votingEscrowFacet = new VotingEscrowFacet(
            address(_portfolioFactory), address(_portfolioAccountConfig),
            address(_ve), address(_voter)
        );
        bytes4[] memory votingEscrowSel = new bytes4[](4);
        votingEscrowSel[0] = VotingEscrowFacet.increaseLock.selector;
        votingEscrowSel[1] = VotingEscrowFacet.createLock.selector;
        votingEscrowSel[2] = VotingEscrowFacet.merge.selector;
        votingEscrowSel[3] = VotingEscrowFacet.onERC721Received.selector;
        _facetRegistry.registerFacet(address(votingEscrowFacet), votingEscrowSel, "VotingEscrowFacet");

        // ── 6. MigrationFacet (1 selector) ──
        MigrationFacet migrationFacet = new MigrationFacet(
            address(_portfolioFactory), address(_portfolioAccountConfig), address(_ve)
        );
        bytes4[] memory migrationSel = new bytes4[](1);
        migrationSel[0] = IMigrationFacet.migrate.selector;
        _facetRegistry.registerFacet(address(migrationFacet), migrationSel, "MigrationFacet");

        // ── 7. MarketplaceFacet (6 selectors) ──
        _portfolioMarketplace = new PortfolioMarketplace(
            address(_portfolioManager), address(_ve), 100, FORTY_ACRES_DEPLOYER
        );
        MarketplaceFacet marketplaceFacet = new MarketplaceFacet(
            address(_portfolioFactory), address(_portfolioAccountConfig),
            address(_ve), address(_portfolioMarketplace)
        );
        bytes4[] memory marketplaceSel = new bytes4[](8);
        marketplaceSel[0] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        marketplaceSel[1] = BaseMarketplaceFacet.makeListing.selector;
        marketplaceSel[2] = BaseMarketplaceFacet.cancelListing.selector;
        marketplaceSel[3] = BaseMarketplaceFacet.marketplace.selector;
        marketplaceSel[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        marketplaceSel[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        marketplaceSel[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
        marketplaceSel[7] = BaseMarketplaceFacet.isListingPurchasable.selector;
        _facetRegistry.registerFacet(address(marketplaceFacet), marketplaceSel, "MarketplaceFacet");

        // ── 8. RewardsProcessingFacet (10 selectors) ──
        RewardsProcessingFacet rewardsProcessingFacet = new RewardsProcessingFacet(
            address(_portfolioFactory), address(_portfolioAccountConfig),
            address(_swapConfig), address(_ve), _vault
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
        _facetRegistry.registerFacet(address(rewardsProcessingFacet), rewardsSel, "RewardsProcessingFacet");

        vm.stopPrank();
    }

    // ── Step 6: Set LoanConfig defaults ──────────────────────────────
    function _setLoanConfigDefaults() internal {
        vm.startPrank(FORTY_ACRES_DEPLOYER);
        _loanConfig.setRewardsRate(10000);
        _loanConfig.setMultiplier(100);
        _loanConfig.setLenderPremium(2000);
        _loanConfig.setTreasuryFee(500);
        _loanConfig.setZeroBalanceFee(100);
        _portfolioManager.setAuthorizedCaller(_authorizedCaller, true);
        vm.stopPrank();
    }

    // ── Step 7: Create user portfolio ────────────────────────────────
    function _createUserPortfolio() internal {
        _portfolioAccount = _portfolioFactory.createAccount(_user);
    }

    // ── Step 8: Mint and transfer veNFTs ──────────────────────────────
    function _setupVeNFTs() internal {
        // Primary veNFT: 5000e18 AERO locked, permanent, transferred to portfolio account
        // (Sized so that default rewardsRate=10000/multiplier=100 gives maxLoan ~5000e6 USDC)
        _tokenId = _mockVe.mintTo(address(this), int128(uint128(5000e18)));
        _mockVe.transferFrom(address(this), _portfolioAccount, _tokenId);

        // Advance time (mirrors Setup.sol: vm.warp + vm.roll after transfer)
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // Second veNFT: 2500e18 AERO locked, permanent, owned by _tokenId2Owner
        _tokenId2 = _mockVe.mintTo(_tokenId2Owner, int128(uint128(2500e18)));
    }
}
