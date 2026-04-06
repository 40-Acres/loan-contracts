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
import {console} from "forge-std/console.sol";
import { NoOpVault } from "../../../src/facets/account/vault/NoOpVault.sol";

contract AerodromeRootDeploy is PortfolioFactoryConfigDeploy {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base USDC
    address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address public constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4; // Aerodrome veAERO
    address public constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5; // Aerodrome Voter
    address public constant REWARDS_DISTRIBUTOR = 0x227f65131A261548b057215bB1D5Ab2997964C7d; // Aerodrome RewardsDistributor
    address public constant PORTFOLIO_MANAGER = PORTFOLIO_MANAGER_ADDRESS;


    PortfolioManager public _portfolioManager = PortfolioManager(PORTFOLIO_MANAGER);
    PortfolioFactory public _portfolioFactory;


    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        PortfolioManager portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);
        address portfolioFactory = portfolioManager.factoryBySalt(keccak256(abi.encodePacked("aerodrome")));
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

        SwapConfig swapConfig = SwapConfig(SWAP_CONFIG);
        address votingConfig = address(AERO_VOTING_CONFIG);
        Vault vault = Vault(AERO_USDC_VAULT);

         // Deploy BridgeFacet

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

contract AerodromeLeafDeploy is PortfolioFactoryConfigDeploy {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base USDC
    address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    
    PortfolioManager public _portfolioManager;
    PortfolioFactory public _portfolioFactory;
    
    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    // only deploy the swap and bridge facets
    function _deploy() internal {
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

        // NoOpVault noOpVault = new NoOpVault(portfolioFactory, 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

        // PortfolioMarketplace portfolioMarketplace = new PortfolioMarketplace(address(portfolioManager), address(VOTING_ESCROW), 100, DEPLOYER_ADDRESS);
        // console.log("Deployed PortfolioMarketplace at", address(portfolioMarketplace));

        // Read existing Aerodrome deployment configs
        // SwapConfig swapConfig = SwapConfig(SWAP_CONFIG);
        // address votingConfig = AERO_VOTING_CONFIG;
        // address loanConfig = address(PortfolioFactory(portfolioFactory).portfolioFactoryConfig().getLoanConfig());
        // Vault vault = Vault(AERO_USDC_VAULT);

        // // Deploy ClaimingFacet
        // ClaimingFacet claimingFacet = new ClaimingFacet(portfolioFactory, VOTING_ESCROW, VOTER, REWARDS_DISTRIBUTOR, address(loanConfig), address(swapConfig), address(vault));
        // bytes4[] memory claimingSelectors = new bytes4[](3);
        // claimingSelectors[0] = ClaimingFacet.claimFees.selector;
        // claimingSelectors[1] = ClaimingFacet.claimRebase.selector;
        // claimingSelectors[2] = ClaimingFacet.claimLaunchpadToken.selector;
        // _registerFacet(facetRegistry, address(claimingFacet), claimingSelectors, "ClaimingFacet");

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
        // bytes4[] memory collateralSelectors = new bytes4[](10);
        // collateralSelectors[0] = BaseCollateralFacet.addCollateral.selector;
        // collateralSelectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        // collateralSelectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        // collateralSelectors[3] = BaseCollateralFacet.getMaxLoan.selector;
        // collateralSelectors[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        // collateralSelectors[5] = BaseCollateralFacet.removeCollateral.selector;
        // collateralSelectors[6] = BaseCollateralFacet.getCollateralToken.selector;
        // collateralSelectors[7] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        // collateralSelectors[8] = BaseCollateralFacet.getLockedCollateral.selector;
        // collateralSelectors[9] = BaseCollateralFacet.removeCollateralTo.selector;
        // _registerFacet(facetRegistry, address(collateralFacet), collateralSelectors, "CollateralFacet");

        // // Deploy MarketplaceFacet
        // MarketplaceFacet marketplaceFacet = new MarketplaceFacet(portfolioFactory, VOTING_ESCROW, address(portfolioMarketplace));
        // bytes4[] memory marketplaceSelectors = new bytes4[](7);
        // marketplaceSelectors[0] = BaseMarketplaceFacet.cancelListing.selector;
        // marketplaceSelectors[1] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        // marketplaceSelectors[2] = BaseMarketplaceFacet.marketplace.selector;
        // marketplaceSelectors[3] = BaseMarketplaceFacet.makeListing.selector;
        // marketplaceSelectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        // marketplaceSelectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        // marketplaceSelectors[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
        // _registerFacet(facetRegistry, address(marketplaceFacet), marketplaceSelectors, "MarketplaceFacet");


        // Upgrade VotingFacet with missing selectors (batchVote, batchVoteForLaunchpadToken, isElligibleForManualVoting)
        address votingConfig = address(AERO_VOTING_CONFIG);
        VotingFacet votingFacet = new VotingFacet(portfolioFactory, votingConfig, VOTING_ESCROW, VOTER);
        bytes4[] memory votingSelectors = new bytes4[](8);
        votingSelectors[0] = VotingFacet.vote.selector;
        votingSelectors[1] = VotingFacet.voteForLaunchpadToken.selector;
        votingSelectors[2] = VotingFacet.setVotingMode.selector;
        votingSelectors[3] = VotingFacet.isManualVoting.selector;
        votingSelectors[4] = VotingFacet.defaultVote.selector;
        votingSelectors[5] = VotingFacet.batchVote.selector;
        votingSelectors[6] = VotingFacet.batchVoteForLaunchpadToken.selector;
        votingSelectors[7] = VotingFacet.isElligibleForManualVoting.selector;
        _registerFacet(facetRegistry, address(votingFacet), votingSelectors, "VotingFacet");

        // Upgrade VotingEscrowFacet with missing mergeInternal selector
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
// forge script script/portfolio_account/aerodrome/DeployAerodromeRelayer.s.sol:AerodromeRootDeploy --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/aerodrome/DeployAerodromeRelayer.s.sol:AerodromeLeafDeploy --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/aerodrome/DeployAerodromeRelayer.s.sol:AerodromeRootUpgrade --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
