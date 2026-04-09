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
    PortfolioManager public _portfolioManager;
    PortfolioFactory public _portfolioFactory;
    address public _loanContract;

    function _createConfigImpl() internal override returns (PortfolioFactoryConfig) {
        return new NFTPortfolioFactoryConfig();
    }

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        PortfolioManager portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);
        address portfolioFactory = portfolioManager.factoryBySalt(keccak256(abi.encodePacked("aerodrome-usdc")));
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

        SwapConfig swapConfig = SwapConfig(BASE_SWAP_CONFIG);
        address votingConfig = address(AERO_VOTING_CONFIG);

        // // Link configs on the new PortfolioFactoryConfig (deployer is owner of these)
        portfolioFactoryConfig.setVoteConfig(votingConfig);
        portfolioFactoryConfig.setLoanConfig(address(loanConfig));
        loanConfig.transferOwnership(MULTISIG_ADDRESS);
        portfolioFactoryConfig.transferOwnership(MULTISIG_ADDRESS);
        console.log("Deployed PortfolioFactoryConfig at:", address(portfolioFactoryConfig));
        console.log("Deployed LoanConfig at:", address(loanConfig));
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
        (PortfolioFactoryConfig portfolioFactoryConfig, VotingConfig votingConfig, LoanConfig loanConfig) = PortfolioFactoryConfigDeploy._deploy(false, address(portfolioFactory));
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
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base USDC
    address public constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4; // Aerodrome veAERO
    address public constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5; // Aerodrome Voter
    address public constant REWARDS_DISTRIBUTOR = 0x227f65131A261548b057215bB1D5Ab2997964C7d; // Aerodrome RewardsDistributor
    
    PortfolioManager public _portfolioManager;
    PortfolioFactory public _portfolioFactory;
    address public _loanContract;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        upgradeFacets();
        vm.stopBroadcast();
    }

    function upgradeFacets() internal {
        PortfolioManager portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);
        
        
        address portfolioFactory = portfolioManager.factoryBySalt(keccak256(abi.encodePacked("aerodrome-usdc")));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        // PortfolioFactoryConfig portfolioFactoryConfig = PortfolioFactory(portfolioFactory).portfolioFactoryConfig();
        address votingConfig = address(AERO_VOTING_CONFIG);
        // address loanConfig = address(portfolioFactoryConfig.getLoanConfig());
        address loanConfig = 0xa5b8bC2C39c669132930AdFD3e56E988e5629C88;
        SwapConfig swapConfig = SwapConfig(BASE_SWAP_CONFIG);
        FacetRegistry facetRegistry = PortfolioFactory(portfolioFactory).facetRegistry();

        // portfolioFactoryConfig.setVoteConfig(address(0xdebEE5c3DFa953DBb1a48819dfF3cC9c12226E0C));
        
        VotingConfig _votingConfig = VotingConfig(votingConfig);


        // // Deploy RewardsProcessingFacet
        RewardsProcessingFacet rewardsProcessingFacet = new VotingEscrowRewardsProcessingFacet(address(portfolioFactory), address(swapConfig), VOTING_ESCROW, address(AERO_USDC_VAULT), IVotingEscrow(VOTING_ESCROW).token());
        bytes4[] memory rewardsProcessingSelectors = new bytes4[](5);
        rewardsProcessingSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        rewardsProcessingSelectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        rewardsProcessingSelectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        rewardsProcessingSelectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        rewardsProcessingSelectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        _registerFacet(facetRegistry, address(rewardsProcessingFacet), rewardsProcessingSelectors, "RewardsProcessingFacet");
        // // Deploy RewardsConfigFacet (on-chain code is 87-byte stub)
        // RewardsConfigFacet rewardsConfigFacet = new RewardsConfigFacet(address(portfolioFactory));
        // bytes4[] memory rewardsConfigSelectors = new bytes4[](7);
        // rewardsConfigSelectors[0] = RewardsConfigFacet.setRewardsToken.selector;
        // rewardsConfigSelectors[1] = RewardsConfigFacet.setRecipient.selector;
        // rewardsConfigSelectors[2] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        // rewardsConfigSelectors[3] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        // rewardsConfigSelectors[4] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        // rewardsConfigSelectors[5] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        // rewardsConfigSelectors[6] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        // _registerFacet(facetRegistry, address(rewardsConfigFacet), rewardsConfigSelectors, "RewardsConfigFacet");

        // // Deploy ClaimingFacet
        // ClaimingFacet claimingFacet = new ClaimingFacet(address(portfolioFactory), VOTING_ESCROW, VOTER, REWARDS_DISTRIBUTOR, address(loanConfig), address(swapConfig), address(AERO_USDC_VAULT));
        // bytes4[] memory claimingSelectors = new bytes4[](3);
        // claimingSelectors[0] = ClaimingFacet.claimFees.selector;
        // claimingSelectors[1] = ClaimingFacet.claimRebase.selector;
        // claimingSelectors[2] = ClaimingFacet.claimLaunchpadToken.selector;
        // _registerFacet(facetRegistry, address(claimingFacet), claimingSelectors, "ClaimingFacet");
        
        // // Deploy LendingFacet (on-chain code is 87-byte stub)
        // LendingFacet lendingFacet = new LendingFacet(address(portfolioFactory), USDC);
        // bytes4[] memory lendingSelectors = new bytes4[](7);
        // lendingSelectors[0] = BaseLendingFacet.borrow.selector;
        // lendingSelectors[1] = BaseLendingFacet.pay.selector;
        // lendingSelectors[2] = BaseLendingFacet.setTopUp.selector;
        // lendingSelectors[3] = BaseLendingFacet.topUp.selector;
        // lendingSelectors[4] = BaseLendingFacet.borrowTo.selector;
        // lendingSelectors[5] = BaseLendingFacet.getPortfolioFactoryConfig.selector;
        // lendingSelectors[6] = BaseLendingFacet.getLendingToken.selector;
        // _registerFacet(facetRegistry, address(lendingFacet), lendingSelectors, "LendingFacet");

        // // Deploy MarketplaceFacet (on-chain code is empty)
        // MarketplaceFacet marketplaceFacet = new MarketplaceFacet(address(portfolioFactory), VOTING_ESCROW, address(VEAERO_MARKETPLACE));
        // bytes4[] memory marketplaceSelectors = new bytes4[](7);
        // marketplaceSelectors[0] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        // marketplaceSelectors[1] = BaseMarketplaceFacet.makeListing.selector;
        // marketplaceSelectors[2] = BaseMarketplaceFacet.cancelListing.selector;
        // marketplaceSelectors[3] = BaseMarketplaceFacet.marketplace.selector;
        // marketplaceSelectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        // marketplaceSelectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        // marketplaceSelectors[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
        // _registerFacet(facetRegistry, address(marketplaceFacet), marketplaceSelectors, "MarketplaceFacet");


        // // Deploy VotingFacet (on-chain code is empty)
        // VotingFacet votingFacet = new VotingFacet(address(portfolioFactory), votingConfig, VOTING_ESCROW, VOTER);
        // bytes4[] memory votingSelectors = new bytes4[](8);
        // votingSelectors[0] = VotingFacet.vote.selector;
        // votingSelectors[1] = VotingFacet.voteForLaunchpadToken.selector;
        // votingSelectors[2] = VotingFacet.setVotingMode.selector;
        // votingSelectors[3] = VotingFacet.isManualVoting.selector;
        // votingSelectors[4] = VotingFacet.defaultVote.selector;
        // votingSelectors[5] = VotingFacet.batchVote.selector;
        // votingSelectors[6] = VotingFacet.batchVoteForLaunchpadToken.selector;
        // votingSelectors[7] = VotingFacet.isElligibleForManualVoting.selector;
        // _registerFacet(facetRegistry, address(votingFacet), votingSelectors, "VotingFacet");

        // // Deploy VotingEscrowFacet (on-chain code is empty)
        // VotingEscrowFacet votingEscrowFacet = new VotingEscrowFacet(address(portfolioFactory), VOTING_ESCROW, VOTER);
        // bytes4[] memory votingEscrowSelectors = new bytes4[](5);
        // votingEscrowSelectors[0] = VotingEscrowFacet.increaseLock.selector;
        // votingEscrowSelectors[1] = VotingEscrowFacet.createLock.selector;
        // votingEscrowSelectors[2] = VotingEscrowFacet.merge.selector;
        // votingEscrowSelectors[3] = VotingEscrowFacet.onERC721Received.selector;
        // votingEscrowSelectors[4] = VotingEscrowFacet.mergeInternal.selector;
        // _registerFacet(facetRegistry, address(votingEscrowFacet), votingEscrowSelectors, "VotingEscrowFacet");

        // Deploy CollateralFacet (on-chain code is empty)
        CollateralFacet collateralFacet = new CollateralFacet(address(portfolioFactory), VOTING_ESCROW);
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


        // // // Upgrade Loan Contract
        // LoanV2 loanImplementation = new LoanV2();
        // // LoanV2(address(portfolioFactoryConfig.getLoanContract())).upgradeToAndCall(address(loanImplementation), new bytes(0));

        // _upgradePortfolioFactoryConfig(portfolioFactoryConfig);

        // Deploy MigrationFacet
        // MigrationFacet migrationFacet = new MigrationFacet(address(portfolioFactory), VOTING_ESCROW);
        // bytes4[] memory migrationSelectors = new bytes4[](1);
        // migrationSelectors[0] = IMigrationFacet.migrate.selector;
        // _registerFacet(facetRegistry, address(migrationFacet), migrationSelectors, "MigrationFacet");

        // Post-upgrade validation - reverts the entire script if anything is wrong
        // _validateDeployment(portfolioFactoryConfig, address(_portfolioFactory));
    }


    function _upgradePortfolioFactoryConfig(PortfolioFactoryConfig portfolioFactoryConfig) internal {
        NFTPortfolioFactoryConfig portfolioFactoryConfigImplementation = new NFTPortfolioFactoryConfig();
        PortfolioFactoryConfig(address(portfolioFactoryConfig)).upgradeToAndCall(address(portfolioFactoryConfigImplementation), new bytes(0));
    }

    /// @dev Post-deployment validation. Reverts the script if any proxy is misconfigured.
    ///      Covers both borrow() and pay() call chains including getMaxLoan() dependencies.
    function _validateDeployment(PortfolioFactoryConfig config, address expectedFactory) internal view {
        // Config proxy: getPortfolioFactory must work and return expected value
        require(config.getPortfolioFactory() == expectedFactory, "Validation: config.getPortfolioFactory() mismatch");
        require(config.getLoanContract() != address(0), "Validation: config.getLoanContract() is zero");
        require(config.getVoteConfig() != address(0), "Validation: config.getVoteConfig() is zero");
        require(address(config.getLoanConfig()) != address(0), "Validation: config.getLoanConfig() is zero");
        require(config.getVault() != address(0), "Validation: config.getVault() is zero");

        // Loan proxy: getPortfolioFactory must match
        address loanProxy = config.getLoanContract();
        require(
            LoanV2(payable(loanProxy)).getPortfolioFactory() == expectedFactory,
            "Validation: loan.getPortfolioFactory() mismatch"
        );

        // Pay flow: lendingAsset and lendingVault must be callable on the loan proxy
        require(ILendingPool(loanProxy).lendingAsset() != address(0), "Validation: lendingAsset() is zero");
        require(ILendingPool(loanProxy).lendingVault() != address(0), "Validation: lendingVault() is zero");

        // getMaxLoan() dependencies: activeAssets, LoanConfig.getRewardsRate/getMultiplier
        ILendingPool(loanProxy).activeAssets();
        config.getLoanConfig().getRewardsRate();
        config.getLoanConfig().getMultiplier();
    }

}
contract UpgradeMarketplaceFacet is Script {
    address public constant DEPLOYER_ADDRESS = 0x40FecA5f7156030b78200450852792ea93f7c6cd;

    function run() external {
        address portfolioFactory = address(0xfeEB5C58786617230095a008164b096e3205EAF2);
        FacetRegistry facetRegistry = PortfolioFactory(portfolioFactory).facetRegistry();

        // Get the existing MarketplaceFacet address
        address existingFacet = facetRegistry.getFacetForSelector(BaseMarketplaceFacet.receiveSaleProceeds.selector);
        require(existingFacet != address(0), "MarketplaceFacet not found");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        // Remove and re-register with all selectors including isListingPurchasable
        facetRegistry.removeFacet(existingFacet);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        selectors[1] = BaseMarketplaceFacet.makeListing.selector;
        selectors[2] = BaseMarketplaceFacet.cancelListing.selector;
        selectors[3] = BaseMarketplaceFacet.marketplace.selector;
        selectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        selectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        selectors[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
        selectors[7] = BaseMarketplaceFacet.isListingPurchasable.selector;

        facetRegistry.registerFacet(existingFacet, selectors, "MarketplaceFacet");

        vm.stopBroadcast();
    }
}

// forge script script/portfolio_account/aerodrome/DeployAerodrome.s.sol:AerodromeRootDeploy --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/aerodrome/DeployAerodrome.s.sol:AerodromeLeafDeploy --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/aerodrome/DeployAerodrome.s.sol:UpgradeMarketplaceFacet --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/aerodrome/DeployAerodrome.s.sol:AerodromeRootUpgrade --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
