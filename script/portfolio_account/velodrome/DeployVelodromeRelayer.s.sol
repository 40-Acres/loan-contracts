// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {NFTPortfolioFactoryConfig} from "../../../src/facets/account/config/NFTPortfolioFactoryConfig.sol";
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
import {SuperchainVotingFacet} from "../../../src/facets/account/vote/SuperchainVoting.sol";
import {SuperchainVotingConfig} from "../../../src/facets/account/config/SuperchainVotingConfig.sol";
import {SuperchainClaimingFacet} from "../../../src/facets/account/claim/SuperchainClaimingFacet.sol";
import {console} from "forge-std/console.sol";
import {NoOpVault} from "../../../src/facets/account/vault/NoOpVault.sol";

contract VelodromeRootDeploy is PortfolioFactoryConfigDeploy {
    address public constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // OP USDC
    address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address public constant VOTING_ESCROW = 0xFAf8FD17D9840595845582fCB047DF13f006787d; // Velodrome veVELO
    address public constant VOTER = 0x41C914ee0c7E1A5edCD0295623e6dC557B5aBf3C; // Velodrome Voter
    address public constant REWARDS_DISTRIBUTOR = 0x9D4736EC60715e71aFe72973f7885DCBC21EA99b; // Velodrome RewardsDistributor
    address public constant VELODROME_PM = 0x5f3736D7686edb3F74c0726D8fDF3f58252cC1F9;

    PortfolioManager public _portfolioManager = PortfolioManager(VELODROME_PM);
    PortfolioFactory public _portfolioFactory;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        PortfolioManager portfolioManager = PortfolioManager(VELODROME_PM);
        address portfolioFactory = portfolioManager.factoryBySalt(keccak256(abi.encodePacked("velodrome")));
        FacetRegistry facetRegistry = PortfolioFactory(portfolioFactory).facetRegistry();

        // Deploy fresh PortfolioFactoryConfig and LoanConfig (no rewards rate/multiplier)
        PortfolioFactoryConfig configImpl = new NFTPortfolioFactoryConfig();
        PortfolioFactoryConfig portfolioFactoryConfig = PortfolioFactoryConfig(
            address(new ERC1967Proxy(
                address(configImpl),
                abi.encodeCall(PortfolioFactoryConfig.initialize, (DEPLOYER_ADDRESS, portfolioFactory))
            ))
        );

        LoanConfig loanConfigImpl = new LoanConfig();
        LoanConfig loanConfig = LoanConfig(
            address(new ERC1967Proxy(
                address(loanConfigImpl),
                abi.encodeCall(LoanConfig.initialize, (DEPLOYER_ADDRESS, 20_00, 5_00, 1_00))
            ))
        );

        SwapConfig swapConfig = SwapConfig(OP_SWAP_CONFIG);
        address votingConfig = VELO_VOTING_CONFIG;

        // // Link configs on the new PortfolioFactoryConfig (deployer is owner of these)
        portfolioFactoryConfig.setVoteConfig(votingConfig);
        portfolioFactoryConfig.setLoanConfig(address(loanConfig));
        loanConfig.transferOwnership(MULTISIG_ADDRESS);
        portfolioFactoryConfig.transferOwnership(MULTISIG_ADDRESS);
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

contract VelodromeRootUpgrade is PortfolioFactoryConfigDeploy {
    address public constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // OP USDC
    address public constant VOTING_ESCROW = 0xFAf8FD17D9840595845582fCB047DF13f006787d; // Velodrome veVELO
    address public constant VOTER = 0x41C914ee0c7E1A5edCD0295623e6dC557B5aBf3C; // Velodrome Voter
    address public constant REWARDS_DISTRIBUTOR = 0x9D4736EC60715e71aFe72973f7885DCBC21EA99b; // Velodrome RewardsDistributor
    address public constant VELODROME_PM = 0x5f3736D7686edb3F74c0726D8fDF3f58252cC1F9;
    // TODO: fill in real address of existing marketplace facet on OP
    address public constant EXISTING_MARKETPLACE_FACET = address(0);

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        upgradeFacets();
        vm.stopBroadcast();
    }

    function upgradeFacets() internal {
        // Get relayer's factory from PortfolioManager
        PortfolioManager portfolioManager = PortfolioManager(VELODROME_PM);
        address portfolioFactory = portfolioManager.factoryBySalt(keccak256(abi.encodePacked("velodrome")));
        FacetRegistry facetRegistry = PortfolioFactory(portfolioFactory).facetRegistry();

        // NoOpVault noOpVault = new NoOpVault(portfolioFactory, USDC);

        // Read existing Velodrome deployment configs
        // SwapConfig swapConfig = SwapConfig(OP_SWAP_CONFIG);
        // address loanConfig = address(PortfolioFactory(portfolioFactory).portfolioFactoryConfig().getLoanConfig());
        // address votingConfig = PortfolioFactory(portfolioFactory).portfolioFactoryConfig().getVoteConfig();
        // Vault vault = Vault(ILoan(PortfolioFactory(portfolioFactory).portfolioFactoryConfig().getLoanContract())._vault());

        // // Deploy SuperchainClaimingFacet
        // SuperchainClaimingFacet superchainClaimingFacet = new SuperchainClaimingFacet();
        // bytes4[] memory superchainClaimingSelectors = new bytes4[](1);
        // superchainClaimingSelectors[0] = SuperchainClaimingFacet.claimSuperchainRewards.selector;
        // _registerFacet(facetRegistry, address(superchainClaimingFacet), superchainClaimingSelectors, "SuperchainClaimingFacet");

        // // Deploy RewardsProcessingFacet
        // RewardsProcessingFacet rewardsProcessingFacet = new VotingEscrowRewardsProcessingFacet(portfolioFactory, address(swapConfig), VOTING_ESCROW, address(vault), IVotingEscrow(VOTING_ESCROW).token());
        // bytes4[] memory rewardsProcessingSelectors = new bytes4[](5);
        // rewardsProcessingSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        // rewardsProcessingSelectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        // rewardsProcessingSelectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        // rewardsProcessingSelectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        // rewardsProcessingSelectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        // _registerFacet(facetRegistry, address(rewardsProcessingFacet), rewardsProcessingSelectors, "RewardsProcessingFacet");

        // // Deploy RewardsConfigFacet
        // RewardsConfigFacet rewardsConfigFacet = new RewardsConfigFacet(portfolioFactory);
        // bytes4[] memory rewardsConfigSelectors = new bytes4[](7);
        // rewardsConfigSelectors[0] = RewardsConfigFacet.setRewardsToken.selector;
        // rewardsConfigSelectors[1] = RewardsConfigFacet.setRecipient.selector;
        // rewardsConfigSelectors[2] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        // rewardsConfigSelectors[3] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        // rewardsConfigSelectors[4] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        // rewardsConfigSelectors[5] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        // rewardsConfigSelectors[6] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        // _registerFacet(facetRegistry, address(rewardsConfigFacet), rewardsConfigSelectors, "RewardsConfigFacet");

        // // Deploy CollateralFacet
        // CollateralFacet collateralFacet = new CollateralFacet(portfolioFactory, VOTING_ESCROW);
        // bytes4[] memory collateralSelectors = new bytes4[](11);
        // collateralSelectors[0] = BaseCollateralFacet.addCollateral.selector;
        // collateralSelectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        // collateralSelectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        // collateralSelectors[3] = BaseCollateralFacet.getMaxLoan.selector;
        // collateralSelectors[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        // collateralSelectors[5] = BaseCollateralFacet.removeCollateral.selector;
        // collateralSelectors[6] = BaseCollateralFacet.removeCollateralTo.selector;
        // collateralSelectors[7] = BaseCollateralFacet.getCollateralToken.selector;
        // collateralSelectors[8] = BaseCollateralFacet.getLockedCollateral.selector;
        // collateralSelectors[9] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        // collateralSelectors[10] = BaseCollateralFacet.getLTVRatio.selector;
        // _registerFacet(facetRegistry, address(collateralFacet), collateralSelectors, "CollateralFacet");

        // Re-register existing MarketplaceFacet with isListingPurchasable selector added
        // Both calls require onlyOwner (multisig) — output Safe calldata
        bytes4[] memory marketplaceSelectors = new bytes4[](8);
        marketplaceSelectors[0] = BaseMarketplaceFacet.cancelListing.selector;
        marketplaceSelectors[1] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        marketplaceSelectors[2] = BaseMarketplaceFacet.marketplace.selector;
        marketplaceSelectors[3] = BaseMarketplaceFacet.makeListing.selector;
        marketplaceSelectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        marketplaceSelectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        marketplaceSelectors[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
        marketplaceSelectors[7] = BaseMarketplaceFacet.isListingPurchasable.selector;

        console.log("=== Safe Transaction 1: removeFacet ===");
        console.log("To (FacetRegistry):", address(facetRegistry));
        console.log("Calldata:");
        console.logBytes(abi.encodeWithSelector(FacetRegistry.removeFacet.selector, EXISTING_MARKETPLACE_FACET));

        console.log("=== Safe Transaction 2: registerFacet ===");
        console.log("To (FacetRegistry):", address(facetRegistry));
        console.log("Calldata:");
        console.logBytes(abi.encodeWithSelector(FacetRegistry.registerFacet.selector, EXISTING_MARKETPLACE_FACET, marketplaceSelectors, "MarketplaceFacet"));

        // Deploy SuperchainVotingFacet with missing selectors
        // SuperchainVotingConfig votingConfig = SuperchainVotingConfig(PortfolioFactory(portfolioFactory).portfolioFactoryConfig().getVoteConfig());
        // SuperchainVotingFacet votingFacet = new SuperchainVotingFacet(portfolioFactory, address(votingConfig), VOTING_ESCROW, VOTER);
        // bytes4[] memory votingSelectors = new bytes4[](8);
        // votingSelectors[0] = SuperchainVotingFacet.vote.selector;
        // votingSelectors[1] = VotingFacet.voteForLaunchpadToken.selector;
        // votingSelectors[2] = VotingFacet.setVotingMode.selector;
        // votingSelectors[3] = VotingFacet.isManualVoting.selector;
        // votingSelectors[4] = VotingFacet.defaultVote.selector;
        // votingSelectors[5] = VotingFacet.batchVote.selector;
        // votingSelectors[6] = VotingFacet.batchVoteForLaunchpadToken.selector;
        // votingSelectors[7] = VotingFacet.isElligibleForManualVoting.selector;
        // _registerFacet(facetRegistry, address(votingFacet), votingSelectors, "VotingFacet");

        // VotingEscrowFacet - mergeInternal toToken listing guard
        VotingEscrowFacet votingEscrowFacet = new VotingEscrowFacet(portfolioFactory, VOTING_ESCROW, VOTER);
        bytes4[] memory votingEscrowSelectors = new bytes4[](5);
        votingEscrowSelectors[0] = VotingEscrowFacet.increaseLock.selector;
        votingEscrowSelectors[1] = VotingEscrowFacet.createLock.selector;
        votingEscrowSelectors[2] = VotingEscrowFacet.merge.selector;
        votingEscrowSelectors[3] = VotingEscrowFacet.onERC721Received.selector;
        votingEscrowSelectors[4] = VotingEscrowFacet.mergeInternal.selector;
        _registerFacet(facetRegistry, address(votingEscrowFacet), votingEscrowSelectors, "VotingEscrowFacet");

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
// forge script script/portfolio_account/velodrome/DeployVelodromeRelayer.s.sol:VelodromeRootDeploy --chain-id 10 --rpc-url $OP_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/velodrome/DeployVelodromeRelayer.s.sol:VelodromeRootUpgrade --chain-id 10 --rpc-url $OP_RPC_URL --broadcast --verify --via-ir
