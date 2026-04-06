// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {PortfolioFactoryConfigDeploy} from "../DeployPortfolioFactoryConfig.s.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {BridgeFacet} from "../../../src/facets/account/bridge/BridgeFacet.sol";

import {ClaimingFacet} from "../../../src/facets/account/claim/ClaimingFacet.sol";
import {DynamicCollateralFacet} from "../../../src/facets/account/collateral/DynamicCollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {DynamicLendingFacet} from "../../../src/facets/account/lending/DynamicLendingFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";
import {DynamicVotingEscrowFacet} from "../../../src/facets/account/votingEscrow/DynamicVotingEscrowFacet.sol";
import {MigrationFacet} from "../../../src/facets/account/migration/MigrationFacet.sol";
import {VexyFacet} from "../../../src/facets/account/marketplace/VexyFacet.sol";
import {OpenXFacet} from "../../../src/facets/account/marketplace/OpenXFacet.sol";
import {DynamicRewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/DynamicRewardsProcessingFacet.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {DynamicMarketplaceFacet} from "../../../src/facets/account/marketplace/DynamicMarketplaceFacet.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IMigrationFacet} from "../../../src/facets/account/migration/IMigrationFacet.sol";
import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../src/facets/marketplace/PortfolioMarketplace.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";

contract AerodromeDynamicFeesRootDeploy is PortfolioFactoryConfigDeploy {
    // Existing deployed addresses
    address public constant EXISTING_PORTFOLIO_FACTORY = 0xfeEB5C58786617230095a008164b096e3205EAF2;

    // Base chain addresses
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address public constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4; // Aerodrome veAERO
    address public constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5; // Aerodrome Voter
    address public constant REWARDS_DISTRIBUTOR = 0x227f65131A261548b057215bB1D5Ab2997964C7d; // Aerodrome RewardsDistributor

    PortfolioFactory public _portfolioFactory;
    DynamicFeesVault public _vault;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        // Get existing PortfolioManager from existing factory
        PortfolioManager portfolioManager = PortfolioFactory(EXISTING_PORTFOLIO_FACTORY).portfolioManager();

        // Use existing swap config
        SwapConfig swapConfig = SwapConfig(SWAP_CONFIG);

        // Deploy new PortfolioFactory with new FacetRegistry for dynamic fees
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = portfolioManager.deployFactory(
            bytes32(keccak256(abi.encodePacked("aerodrome-usdc-dynamic-fees")))
        );
        _portfolioFactory = portfolioFactory;

        // Deploy new PortfolioFactoryConfig for this factory
        PortfolioFactoryConfig configImpl = new PortfolioFactoryConfig();
        ERC1967Proxy configProxy = new ERC1967Proxy(address(configImpl), "");
        PortfolioFactoryConfig portfolioFactoryConfig = PortfolioFactoryConfig(address(configProxy));
        portfolioFactoryConfig.initialize(DEPLOYER_ADDRESS, address(portfolioFactory));

        // Deploy new VotingConfig
        VotingConfig votingConfigImpl = new VotingConfig();
        ERC1967Proxy votingConfigProxy = new ERC1967Proxy(address(votingConfigImpl), "");
        VotingConfig votingConfig = VotingConfig(address(votingConfigProxy));
        votingConfig.initialize(DEPLOYER_ADDRESS);

        // Deploy new LoanConfig
        LoanConfig loanConfigImpl = new LoanConfig();
        ERC1967Proxy loanConfigProxy = new ERC1967Proxy(address(loanConfigImpl), "");
        LoanConfig loanConfig = LoanConfig(address(loanConfigProxy));
        loanConfig.initialize(DEPLOYER_ADDRESS, 20_00, 5_00, 1_00);

        // Set default loan config values
        loanConfig.setRewardsRate(2850);
        loanConfig.setMultiplier(52);

        // Set configs
        portfolioFactoryConfig.setVoteConfig(address(votingConfig));
        portfolioFactoryConfig.setLoanConfig(address(loanConfig));

        // Deploy DynamicFeesVault with proxyd

        // Initialize DynamicFeesVault
        _vault.initialize(USDC, "40base-USDC-DYNAMIC-VAULT", "40base-USDC-DV", address(portfolioFactory));

        // Set the vault as the loan contract in config (DynamicFeesVault implements ILendingPool)
        portfolioFactoryConfig.setLoanContract(address(_vault));
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        // Deploy ClaimingFacet
        ClaimingFacet claimingFacet = new ClaimingFacet(address(portfolioFactory), VOTING_ESCROW, VOTER, REWARDS_DISTRIBUTOR, address(loanConfig), address(swapConfig), address(_vault));
        bytes4[] memory claimingSelectors = new bytes4[](3);
        claimingSelectors[0] = ClaimingFacet.claimFees.selector;
        claimingSelectors[1] = ClaimingFacet.claimRebase.selector;
        claimingSelectors[2] = ClaimingFacet.claimLaunchpadToken.selector;
        _registerFacet(facetRegistry, address(claimingFacet), claimingSelectors, "ClaimingFacet");

        // Deploy DynamicCollateralFacet (uses DynamicCollateralManager storage for DynamicFeesVault)
        DynamicCollateralFacet collateralFacet = new DynamicCollateralFacet(address(portfolioFactory), VOTING_ESCROW);
        bytes4[] memory collateralSelectors = new bytes4[](11);
        collateralSelectors[0] = BaseCollateralFacet.addCollateral.selector;
        collateralSelectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        collateralSelectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        collateralSelectors[3] = BaseCollateralFacet.getMaxLoan.selector;
        collateralSelectors[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        collateralSelectors[5] = BaseCollateralFacet.removeCollateral.selector;
        collateralSelectors[6] = BaseCollateralFacet.getCollateralToken.selector;
        collateralSelectors[7] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        collateralSelectors[8] = BaseCollateralFacet.getLockedCollateral.selector;
        collateralSelectors[9] = BaseCollateralFacet.removeCollateralTo.selector;
        _registerFacet(facetRegistry, address(collateralFacet), collateralSelectors, "DynamicCollateralFacet");

        // Deploy DynamicLendingFacet (uses DynamicCollateralManager for debt tracking)
        DynamicLendingFacet lendingFacet = new DynamicLendingFacet(address(portfolioFactory), USDC);
        bytes4[] memory lendingSelectors = new bytes4[](5);
        lendingSelectors[0] = BaseLendingFacet.borrow.selector;
        lendingSelectors[1] = BaseLendingFacet.pay.selector;
        lendingSelectors[2] = BaseLendingFacet.setTopUp.selector;
        lendingSelectors[3] = BaseLendingFacet.topUp.selector;
        lendingSelectors[4] = BaseLendingFacet.borrowTo.selector;
        _registerFacet(facetRegistry, address(lendingFacet), lendingSelectors, "DynamicLendingFacet");

        // Deploy VotingFacet
        VotingFacet votingFacet = new VotingFacet(address(portfolioFactory), address(votingConfig), VOTING_ESCROW, VOTER);
        bytes4[] memory votingSelectors = new bytes4[](5);
        votingSelectors[0] = VotingFacet.vote.selector;
        votingSelectors[1] = VotingFacet.voteForLaunchpadToken.selector;
        votingSelectors[2] = VotingFacet.setVotingMode.selector;
        votingSelectors[3] = VotingFacet.isManualVoting.selector;
        votingSelectors[4] = VotingFacet.defaultVote.selector;
        _registerFacet(facetRegistry, address(votingFacet), votingSelectors, "VotingFacet");

        // Deploy DynamicVotingEscrowFacet (uses DynamicCollateralManager for collateral updates)
        DynamicVotingEscrowFacet votingEscrowFacet = new DynamicVotingEscrowFacet(address(portfolioFactory), VOTING_ESCROW, VOTER);
        bytes4[] memory votingEscrowSelectors = new bytes4[](4);
        votingEscrowSelectors[0] = DynamicVotingEscrowFacet.increaseLock.selector;
        votingEscrowSelectors[1] = DynamicVotingEscrowFacet.createLock.selector;
        votingEscrowSelectors[2] = DynamicVotingEscrowFacet.merge.selector;
        votingEscrowSelectors[3] = DynamicVotingEscrowFacet.onERC721Received.selector;
        _registerFacet(facetRegistry, address(votingEscrowFacet), votingEscrowSelectors, "DynamicVotingEscrowFacet");

        // Deploy MigrationFacet
        MigrationFacet migrationFacet = new MigrationFacet(address(portfolioFactory), VOTING_ESCROW);
        bytes4[] memory migrationSelectors = new bytes4[](1);
        migrationSelectors[0] = IMigrationFacet.migrate.selector;
        _registerFacet(facetRegistry, address(migrationFacet), migrationSelectors, "MigrationFacet");

        // Deploy VexyFacet
        VexyFacet vexyFacet = new VexyFacet(address(portfolioFactory), VOTING_ESCROW);
        bytes4[] memory vexySelectors = new bytes4[](1);
        vexySelectors[0] = VexyFacet.buyVexyListing.selector;
        _registerFacet(facetRegistry, address(vexyFacet), vexySelectors, "VexyFacet");

        // Deploy OpenXFacet
        OpenXFacet openXFacet = new OpenXFacet(address(portfolioFactory), VOTING_ESCROW);
        bytes4[] memory openXSelectors = new bytes4[](1);
        openXSelectors[0] = OpenXFacet.buyOpenXListing.selector;
        _registerFacet(facetRegistry, address(openXFacet), openXSelectors, "OpenXFacet");

        // Deploy MarketplaceFacet
        PortfolioMarketplace portfolioMarketplace = new PortfolioMarketplace(address(portfolioManager), address(VOTING_ESCROW), 100, DEPLOYER_ADDRESS);
        DynamicMarketplaceFacet marketplaceFacet = new DynamicMarketplaceFacet(address(portfolioFactory), VOTING_ESCROW, address(portfolioMarketplace));
        bytes4[] memory marketplaceSelectors = new bytes4[](8);
        marketplaceSelectors[0] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        marketplaceSelectors[1] = BaseMarketplaceFacet.makeListing.selector;
        marketplaceSelectors[2] = BaseMarketplaceFacet.cancelListing.selector;
        marketplaceSelectors[3] = BaseMarketplaceFacet.marketplace.selector;
        marketplaceSelectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        marketplaceSelectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        marketplaceSelectors[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
        marketplaceSelectors[7] = BaseMarketplaceFacet.isListingPurchasable.selector;
        _registerFacet(facetRegistry, address(marketplaceFacet), marketplaceSelectors, "DynamicMarketplaceFacet");

        // Deploy DynamicRewardsProcessingFacet (uses DynamicCollateralManager.decreaseTotalDebt)
        DynamicRewardsProcessingFacet rewardsProcessingFacet = new DynamicRewardsProcessingFacet(address(portfolioFactory), address(swapConfig), VOTING_ESCROW, address(_vault), IVotingEscrow(VOTING_ESCROW).token());
        bytes4[] memory rewardsProcessingSelectors = new bytes4[](5);
        rewardsProcessingSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        rewardsProcessingSelectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        rewardsProcessingSelectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        rewardsProcessingSelectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        rewardsProcessingSelectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        _registerFacet(facetRegistry, address(rewardsProcessingFacet), rewardsProcessingSelectors, "DynamicRewardsProcessingFacet");

        // Deploy RewardsConfigFacet
        RewardsConfigFacet rewardsConfigFacet = new RewardsConfigFacet(address(portfolioFactory));
        bytes4[] memory rewardsConfigSelectors = new bytes4[](7);
        rewardsConfigSelectors[0] = RewardsConfigFacet.setRewardsToken.selector;
        rewardsConfigSelectors[1] = RewardsConfigFacet.setRecipient.selector;
        rewardsConfigSelectors[2] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        rewardsConfigSelectors[3] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        rewardsConfigSelectors[4] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        rewardsConfigSelectors[5] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        rewardsConfigSelectors[6] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        _registerFacet(facetRegistry, address(rewardsConfigFacet), rewardsConfigSelectors, "RewardsConfigFacet");
    }

}

// forge script script/portfolio_account/aerodrome/DeployAerodromeDynamicFees.s.sol:AerodromeDynamicFeesRootDeploy --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir

interface IFactoryWithConfig {
    function portfolioFactoryConfig() external view returns (PortfolioFactoryConfig);
}

contract AerodromeDynamicFeesRootUpgrade is PortfolioFactoryConfigDeploy {
    bytes32 public constant FACTORY_SALT = keccak256(abi.encodePacked("aerodrome-usdc-dynamic-fees"));

    // Base chain addresses
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address public constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address public constant REWARDS_DISTRIBUTOR = 0x227f65131A261548b057215bB1D5Ab2997964C7d;

    // Any existing factory on this PortfolioManager (used to resolve the manager)
    address public constant EXISTING_PORTFOLIO_FACTORY = 0xfeEB5C58786617230095a008164b096e3205EAF2;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        upgradeFacets();
        vm.stopBroadcast();
    }

    function _resolveFromSalt() internal view returns (
        PortfolioFactory portfolioFactory,
        FacetRegistry facetRegistry,
        PortfolioFactoryConfig portfolioFactoryConfig
    ) {
        PortfolioManager portfolioManager = PortfolioFactory(EXISTING_PORTFOLIO_FACTORY).portfolioManager();
        portfolioFactory = PortfolioFactory(portfolioManager.factoryBySalt(FACTORY_SALT));
        require(address(portfolioFactory) != address(0), "Factory not found for salt");
        facetRegistry = portfolioFactory.facetRegistry();

        portfolioFactoryConfig = IFactoryWithConfig(address(portfolioFactory)).portfolioFactoryConfig();
        require(address(portfolioFactoryConfig) != address(0), "PortfolioFactoryConfig not set on factory");
    }

    function upgradeFacets() internal {
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry, PortfolioFactoryConfig portfolioFactoryConfig) = _resolveFromSalt();
        address votingConfig = address(portfolioFactoryConfig.getVoteConfig());
        address loanConfig = address(portfolioFactoryConfig.getLoanConfig());
        SwapConfig swapConfig = SwapConfig(SWAP_CONFIG);

        // The vault IS the loan contract for DynamicFees
        DynamicFeesVault vault = DynamicFeesVault(portfolioFactoryConfig.getLoanContract());

        // // Deploy ClaimingFacet
        // ClaimingFacet claimingFacet = new ClaimingFacet(address(portfolioFactory), VOTING_ESCROW, VOTER, REWARDS_DISTRIBUTOR, address(loanConfig), address(swapConfig), address(vault));
        // bytes4[] memory claimingSelectors = new bytes4[](3);
        // claimingSelectors[0] = ClaimingFacet.claimFees.selector;
        // claimingSelectors[1] = ClaimingFacet.claimRebase.selector;
        // claimingSelectors[2] = ClaimingFacet.claimLaunchpadToken.selector;
        // _registerFacet(facetRegistry, address(claimingFacet), claimingSelectors, "ClaimingFacet");

        // Deploy DynamicCollateralFacet (uses DynamicCollateralManager storage for DynamicFeesVault)
        DynamicCollateralFacet collateralFacet = new DynamicCollateralFacet(address(portfolioFactory), VOTING_ESCROW);
        bytes4[] memory collateralSelectors = new bytes4[](10);
        collateralSelectors[0] = BaseCollateralFacet.addCollateral.selector;
        collateralSelectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        collateralSelectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        collateralSelectors[3] = BaseCollateralFacet.getMaxLoan.selector;
        collateralSelectors[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        collateralSelectors[5] = BaseCollateralFacet.removeCollateral.selector;
        collateralSelectors[6] = BaseCollateralFacet.getCollateralToken.selector;
        collateralSelectors[7] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        collateralSelectors[8] = BaseCollateralFacet.getLockedCollateral.selector;
        collateralSelectors[9] = BaseCollateralFacet.removeCollateralTo.selector;
        _registerFacet(facetRegistry, address(collateralFacet), collateralSelectors, "DynamicCollateralFacet");

        // // Deploy LendingFacet
        // LendingFacet lendingFacet = new LendingFacet(address(portfolioFactory), USDC);
        // bytes4[] memory lendingSelectors = new bytes4[](4);
        // lendingSelectors[0] = BaseLendingFacet.borrow.selector;
        // lendingSelectors[1] = BaseLendingFacet.pay.selector;
        // lendingSelectors[2] = BaseLendingFacet.setTopUp.selector;
        // lendingSelectors[3] = BaseLendingFacet.topUp.selector;
        // _registerFacet(facetRegistry, address(lendingFacet), lendingSelectors, "LendingFacet");

        // // Deploy VotingFacet
        // VotingFacet votingFacet = new VotingFacet(address(portfolioFactory), votingConfig, VOTING_ESCROW, VOTER);
        // bytes4[] memory votingSelectors = new bytes4[](5);
        // votingSelectors[0] = VotingFacet.vote.selector;
        // votingSelectors[1] = VotingFacet.voteForLaunchpadToken.selector;
        // votingSelectors[2] = VotingFacet.setVotingMode.selector;
        // votingSelectors[3] = VotingFacet.isManualVoting.selector;
        // votingSelectors[4] = VotingFacet.defaultVote.selector;
        // _registerFacet(facetRegistry, address(votingFacet), votingSelectors, "VotingFacet");

        // // Deploy VotingEscrowFacet
        // VotingEscrowFacet votingEscrowFacet = new VotingEscrowFacet(address(portfolioFactory), VOTING_ESCROW, VOTER);
        // bytes4[] memory votingEscrowSelectors = new bytes4[](3);
        // votingEscrowSelectors[0] = VotingEscrowFacet.increaseLock.selector;
        // votingEscrowSelectors[1] = VotingEscrowFacet.createLock.selector;
        // votingEscrowSelectors[2] = VotingEscrowFacet.merge.selector;
        // _registerFacet(facetRegistry, address(votingEscrowFacet), votingEscrowSelectors, "VotingEscrowFacet");

        // // Deploy SwapFacet
        // SwapFacet swapFacet = new SwapFacet(address(portfolioFactory), address(portfolioFactoryConfig), address(swapConfig));
        // bytes4[] memory swapSelectors = new bytes4[](1);
        // swapSelectors[0] = SwapFacet.userSwap.selector;
        // _registerFacet(facetRegistry, address(swapFacet), swapSelectors, "SwapFacet");

        // // Deploy MigrationFacet
        // MigrationFacet migrationFacet = new MigrationFacet(address(portfolioFactory), VOTING_ESCROW);
        // bytes4[] memory migrationSelectors = new bytes4[](1);
        // migrationSelectors[0] = IMigrationFacet.migrate.selector;
        // _registerFacet(facetRegistry, address(migrationFacet), migrationSelectors, "MigrationFacet");

        // // Deploy VexyFacet
        // VexyFacet vexyFacet = new VexyFacet(address(portfolioFactory), VOTING_ESCROW);
        // bytes4[] memory vexySelectors = new bytes4[](1);
        // vexySelectors[0] = VexyFacet.buyVexyListing.selector;
        // _registerFacet(facetRegistry, address(vexyFacet), vexySelectors, "VexyFacet");

        // // Deploy OpenXFacet
        // OpenXFacet openXFacet = new OpenXFacet(address(portfolioFactory), VOTING_ESCROW);
        // bytes4[] memory openXSelectors = new bytes4[](1);
        // openXSelectors[0] = OpenXFacet.buyOpenXListing.selector;
        // _registerFacet(facetRegistry, address(openXFacet), openXSelectors, "OpenXFacet");

        // // Deploy MarketplaceFacet
        // PortfolioMarketplace portfolioMarketplace = new PortfolioMarketplace(address(portfolioFactory), address(VOTING_ESCROW), 100, DEPLOYER_ADDRESS);
        // MarketplaceFacet marketplaceFacet = new MarketplaceFacet(address(portfolioFactory), VOTING_ESCROW, address(portfolioMarketplace));
        // bytes4[] memory marketplaceSelectors = new bytes4[](7);
        // marketplaceSelectors[0] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        // marketplaceSelectors[1] = BaseMarketplaceFacet.makeListing.selector;
        // marketplaceSelectors[2] = BaseMarketplaceFacet.cancelListing.selector;
        // marketplaceSelectors[3] = BaseMarketplaceFacet.marketplace.selector;
        // marketplaceSelectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        // marketplaceSelectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        // marketplaceSelectors[6] = BaseMarketplaceFacet.buyMarketplaceListing.selector;
        // _registerFacet(facetRegistry, address(marketplaceFacet), marketplaceSelectors, "MarketplaceFacet");

        // // Deploy ERC721ReceiverFacet
        // ERC721ReceiverFacet erc721ReceiverFacet = new ERC721ReceiverFacet();
        // bytes4[] memory erc721ReceiverSelectors = new bytes4[](1);
        // erc721ReceiverSelectors[0] = ERC721ReceiverFacet.onERC721Received.selector;
        // _registerFacet(facetRegistry, address(erc721ReceiverFacet), erc721ReceiverSelectors, "ERC721ReceiverFacet");

        // Deploy DynamicRewardsProcessingFacet (uses DynamicCollateralManager.decreaseTotalDebt)
        DynamicRewardsProcessingFacet rewardsProcessingFacet = new DynamicRewardsProcessingFacet(address(portfolioFactory), address(swapConfig), VOTING_ESCROW, address(vault), IVotingEscrow(VOTING_ESCROW).token());
        bytes4[] memory rewardsProcessingSelectors = new bytes4[](5);
        rewardsProcessingSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        rewardsProcessingSelectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        rewardsProcessingSelectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        rewardsProcessingSelectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        rewardsProcessingSelectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        _registerFacet(facetRegistry, address(rewardsProcessingFacet), rewardsProcessingSelectors, "DynamicRewardsProcessingFacet");

        // Deploy RewardsConfigFacet
        RewardsConfigFacet rewardsConfigFacet = new RewardsConfigFacet(address(portfolioFactory));
        bytes4[] memory rewardsConfigSelectors = new bytes4[](7);
        rewardsConfigSelectors[0] = RewardsConfigFacet.setRewardsToken.selector;
        rewardsConfigSelectors[1] = RewardsConfigFacet.setRecipient.selector;
        rewardsConfigSelectors[2] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        rewardsConfigSelectors[3] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        rewardsConfigSelectors[4] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        rewardsConfigSelectors[5] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        rewardsConfigSelectors[6] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        _registerFacet(facetRegistry, address(rewardsConfigFacet), rewardsConfigSelectors, "RewardsConfigFacet");

        upgradeVault();
    }

    function upgradeVault() internal {
        (,, PortfolioFactoryConfig portfolioFactoryConfig) = _resolveFromSalt();
        address vaultProxy = portfolioFactoryConfig.getLoanContract();

        // Deploy new DynamicFeesVault implementation and upgrade
        DynamicFeesVault newImplementation = new DynamicFeesVault();
        DynamicFeesVault(vaultProxy).upgradeToAndCall(address(newImplementation), new bytes(0));
    }

}

// forge script script/portfolio_account/aerodrome/DeployAerodromeDynamicFees.s.sol:AerodromeDynamicFeesRootUpgrade --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
