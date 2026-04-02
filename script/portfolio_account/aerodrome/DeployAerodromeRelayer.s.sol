// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {PortfolioFactoryConfigDeploy} from "../DeployPortfolioFactoryConfig.s.sol";
import {BridgeFacet} from "../../../src/facets/account/bridge/BridgeFacet.sol";

import {ClaimingFacet} from "../../../src/facets/account/claim/ClaimingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";
import {VotingEscrowFacet} from "../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {MigrationFacet} from "../../../src/facets/account/migration/MigrationFacet.sol";
import {VexyFacet} from "../../../src/facets/account/marketplace/VexyFacet.sol";
import {OpenXFacet} from "../../../src/facets/account/marketplace/OpenXFacet.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {VotingEscrowRewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/VotingEscrowRewardsProcessingFacet.sol";
import {Loan} from "../../../src/Loan.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";
import {Vault} from "../../../src/VaultV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IMigrationFacet} from "../../../src/facets/account/migration/IMigrationFacet.sol";
import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../src/facets/marketplace/PortfolioMarketplace.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";
import {ILendingPool} from "../../../src/interfaces/ILendingPool.sol";
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {console} from "forge-std/console.sol";

contract AerodromeRootDeploy is PortfolioFactoryConfigDeploy {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base USDC
    address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address public constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4; // Aerodrome veAERO
    address public constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5; // Aerodrome Voter
    address public constant REWARDS_DISTRIBUTOR = 0x227f65131A261548b057215bB1D5Ab2997964C7d; // Aerodrome RewardsDistributor
    bytes32 public constant SALT = bytes32(uint256(0x420ac2e));
    address public constant PORTFOLIO_MANAGER = 0x5f3736D7686edb3F74c0726D8fDF3f58252cC1F9;

    // Reuse existing configs and vault from the Aerodrome deployment
    address public constant EXISTING_AERODROME_CONFIG = 0x400C710cbEadc5bb8b7132B3061fA1b6d6f80Dd8;
    address public constant EXISTING_SWAP_CONFIG = 0x3646C436f18f0e2E38E10D1A147f901a96BD4390;

    PortfolioManager public _portfolioManager = PortfolioManager(PORTFOLIO_MANAGER);
    PortfolioFactory public _portfolioFactory;

    // ============ MULTISIG DEPLOYMENT WORKFLOW ============
    // Step 1: Multisig calls PM.deployFactory(keccak256("aerodrome")) → get factory + registry addresses
    // Step 2: Fill in FACTORY and FACET_REGISTRY below, then run this script
    // Step 3: Use logged calldata to submit multisig txs for setPortfolioFactoryConfig + registerFacet
    // =====================================================

    // Fill these in after Step 1 (multisig deployFactory)
    address public constant FACTORY = address(0); // TODO: fill after deployFactory
    address public constant FACET_REGISTRY = address(0); // TODO: fill after deployFactory

    function run() external {
        require(FACTORY != address(0), "Set FACTORY address first");
        require(FACET_REGISTRY != address(0), "Set FACET_REGISTRY address first");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        PortfolioFactory portfolioFactory = PortfolioFactory(FACTORY);
        FacetRegistry facetRegistry = FacetRegistry(FACET_REGISTRY);

        // Deploy fresh PortfolioFactoryConfig and LoanConfig (no rewards rate/multiplier)
        PortfolioFactoryConfig configImpl = new PortfolioFactoryConfig();
        PortfolioFactoryConfig portfolioFactoryConfig = PortfolioFactoryConfig(
            address(new ERC1967Proxy(
                address(configImpl),
                abi.encodeCall(PortfolioFactoryConfig.initialize, (DEPLOYER_ADDRESS, FACTORY))
            ))
        );

        LoanConfig loanConfigImpl = new LoanConfig();
        LoanConfig loanConfig = LoanConfig(
            address(new ERC1967Proxy(
                address(loanConfigImpl),
                abi.encodeCall(LoanConfig.initialize, (DEPLOYER_ADDRESS))
            ))
        );

        // Reuse existing VotingConfig, SwapConfig, and Vault from the Aerodrome deployment
        PortfolioFactoryConfig existingConfig = PortfolioFactoryConfig(EXISTING_AERODROME_CONFIG);
        SwapConfig swapConfig = SwapConfig(EXISTING_SWAP_CONFIG);
        address votingConfig = address(existingConfig.getVoteConfig());
        address existingLoanContract = existingConfig.getLoanContract();
        Vault vault = Vault(ILoan(existingLoanContract)._vault());

        // Link configs on the new PortfolioFactoryConfig (deployer is owner of these)
        portfolioFactoryConfig.setVoteConfig(votingConfig);
        portfolioFactoryConfig.setLoanConfig(address(loanConfig));

        _portfolioFactory = portfolioFactory;

        // ===== MULTISIG TX 1: setPortfolioFactoryConfig on factory =====
        console.log("=== MULTISIG TRANSACTIONS ===");
        console.log("");
        console.log("TX 1: setPortfolioFactoryConfig");
        console.log("  Target:", FACTORY);
        console.log("  Calldata:");
        console.logBytes(abi.encodeCall(PortfolioFactory.setPortfolioFactoryConfig, (address(portfolioFactoryConfig))));
        console.log("");

        // Deploy ClaimingFacet
        ClaimingFacet claimingFacet = new ClaimingFacet(FACTORY, VOTING_ESCROW, VOTER, REWARDS_DISTRIBUTOR, address(loanConfig), address(swapConfig), address(vault));
        bytes4[] memory claimingSelectors = new bytes4[](3);
        claimingSelectors[0] = ClaimingFacet.claimFees.selector;
        claimingSelectors[1] = ClaimingFacet.claimRebase.selector;
        claimingSelectors[2] = ClaimingFacet.claimLaunchpadToken.selector;
        _logRegisterFacet(2, address(claimingFacet), claimingSelectors, "ClaimingFacet");

        // Deploy CollateralFacet
        CollateralFacet collateralFacet = new CollateralFacet(FACTORY, VOTING_ESCROW);
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
        _logRegisterFacet(3, address(collateralFacet), collateralSelectors, "CollateralFacet");

        // Deploy VotingFacet
        VotingFacet votingFacet = new VotingFacet(FACTORY, votingConfig, VOTING_ESCROW, VOTER);
        bytes4[] memory votingSelectors = new bytes4[](5);
        votingSelectors[0] = VotingFacet.vote.selector;
        votingSelectors[1] = VotingFacet.voteForLaunchpadToken.selector;
        votingSelectors[2] = VotingFacet.setVotingMode.selector;
        votingSelectors[3] = VotingFacet.isManualVoting.selector;
        votingSelectors[4] = VotingFacet.defaultVote.selector;
        _logRegisterFacet(4, address(votingFacet), votingSelectors, "VotingFacet");

        // Deploy VotingEscrowFacet
        VotingEscrowFacet votingEscrowFacet = new VotingEscrowFacet(FACTORY, VOTING_ESCROW, VOTER);
        bytes4[] memory votingEscrowSelectors = new bytes4[](4);
        votingEscrowSelectors[0] = VotingEscrowFacet.increaseLock.selector;
        votingEscrowSelectors[1] = VotingEscrowFacet.createLock.selector;
        votingEscrowSelectors[2] = VotingEscrowFacet.merge.selector;
        votingEscrowSelectors[3] = VotingEscrowFacet.onERC721Received.selector;
        _logRegisterFacet(5, address(votingEscrowFacet), votingEscrowSelectors, "VotingEscrowFacet");

        // Deploy MarketplaceFacet
        PortfolioMarketplace portfolioMarketplace = new PortfolioMarketplace(address(_portfolioManager), address(VOTING_ESCROW), 100, DEPLOYER_ADDRESS);
        MarketplaceFacet marketplaceFacet = new MarketplaceFacet(FACTORY, VOTING_ESCROW, address(portfolioMarketplace));
        bytes4[] memory marketplaceSelectors = new bytes4[](8);
        marketplaceSelectors[0] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        marketplaceSelectors[1] = BaseMarketplaceFacet.makeListing.selector;
        marketplaceSelectors[2] = BaseMarketplaceFacet.cancelListing.selector;
        marketplaceSelectors[3] = BaseMarketplaceFacet.marketplace.selector;
        marketplaceSelectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        marketplaceSelectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        marketplaceSelectors[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
        marketplaceSelectors[7] = BaseMarketplaceFacet.isListingPurchasable.selector;
        _logRegisterFacet(6, address(marketplaceFacet), marketplaceSelectors, "MarketplaceFacet");

        // Deploy RewardsProcessingFacet
        RewardsProcessingFacet rewardsProcessingFacet = new VotingEscrowRewardsProcessingFacet(FACTORY, address(swapConfig), VOTING_ESCROW, address(vault), IVotingEscrow(VOTING_ESCROW).token());
        bytes4[] memory rewardsProcessingSelectors = new bytes4[](5);
        rewardsProcessingSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        rewardsProcessingSelectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        rewardsProcessingSelectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        rewardsProcessingSelectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        rewardsProcessingSelectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        _logRegisterFacet(7, address(rewardsProcessingFacet), rewardsProcessingSelectors, "RewardsProcessingFacet");

        // Deploy RewardsConfigFacet
        RewardsConfigFacet rewardsConfigFacet = new RewardsConfigFacet(FACTORY);
        bytes4[] memory rewardsConfigSelectors = new bytes4[](7);
        rewardsConfigSelectors[0] = RewardsConfigFacet.setRewardsToken.selector;
        rewardsConfigSelectors[1] = RewardsConfigFacet.setRecipient.selector;
        rewardsConfigSelectors[2] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        rewardsConfigSelectors[3] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        rewardsConfigSelectors[4] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        rewardsConfigSelectors[5] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        rewardsConfigSelectors[6] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        _logRegisterFacet(8, address(rewardsConfigFacet), rewardsConfigSelectors, "RewardsConfigFacet");

        // Post-deployment validation
        _validateDeployment(portfolioFactoryConfig, FACTORY);
    }

    /**
     * @dev Logs the registerFacet calldata for Safe multisig Transaction Builder
     */
    function _logRegisterFacet(
        uint256 txNum,
        address facetAddress,
        bytes4[] memory selectors,
        string memory name
    ) internal view {
        console.log("---");
        console.log("TX %d: registerFacet - %s", txNum, name);
        console.log("  Target:", FACET_REGISTRY);
        console.log("  Facet Address:", facetAddress);
        console.log("  Calldata:");
        console.logBytes(abi.encodeWithSelector(FacetRegistry.registerFacet.selector, facetAddress, selectors, name));
        console.log("");
    }

    /// @dev Post-deployment validation. Reverts the script if any proxy is misconfigured.
    function _validateDeployment(PortfolioFactoryConfig config, address expectedFactory) internal view {
        require(config.getPortfolioFactory() == expectedFactory, "Validation: config.getPortfolioFactory() mismatch");
        require(config.getVoteConfig() != address(0), "Validation: config.getVoteConfig() is zero");
        require(address(config.getLoanConfig()) != address(0), "Validation: config.getLoanConfig() is zero");

        require(config.getLoanConfig().getRewardsRate() == 0);
        require(config.getLoanConfig().getMultiplier() == 0);
    }
}

contract AerodromeLeafDeploy is PortfolioFactoryConfigDeploy {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base USDC
    address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    bytes32 public constant SALT = keccak256(abi.encodePacked("aerodrome-usdc"));
    
    PortfolioManager public _portfolioManager;
    PortfolioFactory public _portfolioFactory;
    
    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    // only deploy the swap and bridge facets
    function _deploy() internal {
        _portfolioManager = new PortfolioManager{salt: SALT}(DEPLOYER_ADDRESS);
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _portfolioManager.deployFactory(bytes32(keccak256(abi.encodePacked("aerodrome-usdc"))));
        
        // Use inherited _deploy() function from PortfolioFactoryConfigDeploy
        (PortfolioFactoryConfig portfolioFactoryConfig, VotingConfig votingConfig, LoanConfig loanConfig, SwapConfig swapConfig) = PortfolioFactoryConfigDeploy._deploy(false, address(portfolioFactory));
        _portfolioFactory = portfolioFactory;
        
        // Deploy only swap and bridge facets directly (no contract instances)
        // This allows calls to be broadcast from deployer account
        
        // Deploy BridgeFacet
        // BridgeFacet bridgeFacet = new BridgeFacet(address(portfolioFactory), USDC, TOKEN_MESSENGER, 2);
        // bytes4[] memory bridgeSelectors = new bytes4[](1);
        // bridgeSelectors[0] = BridgeFacet.bridge.selector;
        // Check if facet already exists
        // address oldBridgeFacet = facetRegistry.getFacetForSelector(bridgeSelectors[0]);
        // if (oldBridgeFacet == address(0)) {
        //     facetRegistry.registerFacet(address(bridgeFacet), bridgeSelectors, "BridgeFacet");
        // } else {
        //     facetRegistry.replaceFacet(oldBridgeFacet, address(bridgeFacet), bridgeSelectors, "BridgeFacet");
        // }
        
    }
}



contract AerodromeRootUpgrade is PortfolioFactoryConfigDeploy {
    address public constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4; // Aerodrome veAERO
    address public constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5; // Aerodrome Voter
    address public constant REWARDS_DISTRIBUTOR = 0x227f65131A261548b057215bB1D5Ab2997964C7d; // Aerodrome RewardsDistributor
    address public constant MARKETPLACE = 0x7b22D5D5753B76B5AAF2cC0ac11457e069b9f2C8;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        upgradeFacets();
        vm.stopBroadcast();
    }

    function upgradeFacets() internal {
        // Get relayer's factory from PortfolioManager
        PortfolioManager portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);
        address portfolioFactory = portfolioManager.factoryBySalt(keccak256(abi.encodePacked("aerodrome")));
        FacetRegistry facetRegistry = PortfolioFactory(portfolioFactory).facetRegistry();

        // Read existing Aerodrome deployment configs
        PortfolioFactoryConfig existingConfig = PortfolioFactoryConfig(0x400C710cbEadc5bb8b7132B3061fA1b6d6f80Dd8);
        SwapConfig swapConfig = SwapConfig(0x3646C436f18f0e2E38E10D1A147f901a96BD4390);
        address votingConfig = address(existingConfig.getVoteConfig());
        address existingLoanContract = existingConfig.getLoanContract();
        Vault vault = Vault(ILoan(existingLoanContract)._vault());

        // Step 1: Deploy fresh PortfolioFactoryConfig and LoanConfig
        // PortfolioFactoryConfig configImpl = new PortfolioFactoryConfig();
        PortfolioFactoryConfig portfolioFactoryConfig = PortfolioFactoryConfig(0x34aCa8A6538B43b6CA7DA1CD482fE72369b1b73f);
        PortfolioMarketplace portfolioMarketplace = PortfolioMarketplace(MARKETPLACE);


        LoanConfig loanConfigImpl = new LoanConfig();
        LoanConfig loanConfig = LoanConfig(
            address(new ERC1967Proxy(
                address(loanConfigImpl),
                abi.encodeCall(LoanConfig.initialize, (DEPLOYER_ADDRESS))
            ))
        );

        // Link configs — reuse existing VotingConfig, SwapConfig, LoanContract from Aerodrome deployment
        // portfolioFactoryConfig.setVoteConfig(votingConfig);
        // portfolioFactoryConfig.setLoanConfig(address(loanConfig));
        // portfolioFactoryConfig.setLoanContract(existingLoanContract);
        // portfolioFactoryConfig.setPortfolioFactory(portfolioFactory);

        // // Step 2: Redeploy ClaimingFacet with fresh config
        ClaimingFacet claimingFacet = new ClaimingFacet(portfolioFactory, VOTING_ESCROW, VOTER, REWARDS_DISTRIBUTOR, address(loanConfig), address(swapConfig), address(vault));
        bytes4[] memory claimingSelectors = new bytes4[](3);
        claimingSelectors[0] = ClaimingFacet.claimFees.selector;
        claimingSelectors[1] = ClaimingFacet.claimRebase.selector;
        claimingSelectors[2] = ClaimingFacet.claimLaunchpadToken.selector;
        _registerFacet(facetRegistry, address(claimingFacet), claimingSelectors, "ClaimingFacet");

        // // Step 3: Redeploy RewardsProcessingFacet with fresh config and Aerodrome vault
        RewardsProcessingFacet rewardsProcessingFacet = new VotingEscrowRewardsProcessingFacet(portfolioFactory, address(swapConfig), VOTING_ESCROW, address(vault), IVotingEscrow(VOTING_ESCROW).token());
        bytes4[] memory rewardsProcessingSelectors = new bytes4[](5);
        rewardsProcessingSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        rewardsProcessingSelectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        rewardsProcessingSelectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        rewardsProcessingSelectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        rewardsProcessingSelectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        _registerFacet(facetRegistry, address(rewardsProcessingFacet), rewardsProcessingSelectors, "RewardsProcessingFacet");

        // Deploy RewardsConfigFacet
        RewardsConfigFacet rewardsConfigFacet = new RewardsConfigFacet(portfolioFactory);
        bytes4[] memory rewardsConfigSelectors = new bytes4[](7);
        rewardsConfigSelectors[0] = RewardsConfigFacet.setRewardsToken.selector;
        rewardsConfigSelectors[1] = RewardsConfigFacet.setRecipient.selector;
        rewardsConfigSelectors[2] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        rewardsConfigSelectors[3] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        rewardsConfigSelectors[4] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        rewardsConfigSelectors[5] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        rewardsConfigSelectors[6] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        _registerFacet(facetRegistry, address(rewardsConfigFacet), rewardsConfigSelectors, "RewardsConfigFacet");

        // Step 4: Redeploy all other facets with fresh config
        CollateralFacet collateralFacet = new CollateralFacet(portfolioFactory, VOTING_ESCROW);
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
        _registerFacet(facetRegistry, address(collateralFacet), collateralSelectors, "CollateralFacet");

        VotingFacet votingFacet = new VotingFacet(portfolioFactory, votingConfig, VOTING_ESCROW, VOTER);
        bytes4[] memory votingSelectors = new bytes4[](5);
        votingSelectors[0] = VotingFacet.vote.selector;
        votingSelectors[1] = VotingFacet.voteForLaunchpadToken.selector;
        votingSelectors[2] = VotingFacet.setVotingMode.selector;
        votingSelectors[3] = VotingFacet.isManualVoting.selector;
        votingSelectors[4] = VotingFacet.defaultVote.selector;
        _registerFacet(facetRegistry, address(votingFacet), votingSelectors, "VotingFacet");

        VotingEscrowFacet votingEscrowFacet = new VotingEscrowFacet(portfolioFactory, VOTING_ESCROW, VOTER);
        bytes4[] memory votingEscrowSelectors = new bytes4[](4);
        votingEscrowSelectors[0] = VotingEscrowFacet.increaseLock.selector;
        votingEscrowSelectors[1] = VotingEscrowFacet.createLock.selector;
        votingEscrowSelectors[2] = VotingEscrowFacet.merge.selector;
        votingEscrowSelectors[3] = VotingEscrowFacet.onERC721Received.selector;
        _registerFacet(facetRegistry, address(votingEscrowFacet), votingEscrowSelectors, "VotingEscrowFacet");

        MarketplaceFacet marketplaceFacet = new MarketplaceFacet(portfolioFactory, VOTING_ESCROW, 0x7b22D5D5753B76B5AAF2cC0ac11457e069b9f2C8);
        bytes4[] memory marketplaceSelectors = new bytes4[](7);
        marketplaceSelectors[1] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        marketplaceSelectors[3] = BaseMarketplaceFacet.makeListing.selector;
        marketplaceSelectors[0] = BaseMarketplaceFacet.cancelListing.selector;
        marketplaceSelectors[2] = BaseMarketplaceFacet.marketplace.selector;
        marketplaceSelectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        marketplaceSelectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        marketplaceSelectors[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
        _registerFacet(facetRegistry, address(marketplaceFacet), marketplaceSelectors, "MarketplaceFacet");

        // Post-deployment validation - reverts the entire script if anything is wrong
        // _validateDeployment(portfolioFactoryConfig, portfolioFactory);
    }

    /// @dev Post-deployment validation. Reverts the script if any proxy is misconfigured.
    ///      Covers both borrow() and pay() call chains including getMaxLoan() dependencies.
    function _validateDeployment(PortfolioFactoryConfig config, address expectedFactory) internal view {
        // Config proxy: getPortfolioFactory must work and return expected value
        console.log("Validating PortfolioFactoryConfig at", address(config));
        console.log("Expected PortfolioFactory:", address(expectedFactory));
        console.log("Actual PortfolioFactory:", address(config.getPortfolioFactory()));
        require(config.getPortfolioFactory() == expectedFactory, "Validation: config.getPortfolioFactory() mismatch");
        // require(config.getLoanContract() != address(0), "Validation: config.getLoanContract() is zero");
        require(config.getVoteConfig() != address(0), "Validation: config.getVoteConfig() is zero");
        require(address(config.getLoanConfig()) != address(0), "Validation: config.getLoanConfig() is zero");
    }
}
// forge script script/portfolio_account/aerodrome/DeployAerodromeRelayer.s.sol:AerodromeRootDeploy --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/aerodrome/DeployAerodromeRelayer.s.sol:AerodromeLeafDeploy --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/aerodrome/DeployAerodromeRelayer.s.sol:AerodromeRootUpgrade --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
