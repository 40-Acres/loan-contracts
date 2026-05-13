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
import {RootPoolVotingConfig} from "../../../src/facets/account/config/RootPoolVotingConfig.sol";
import {SuperchainClaimingFacet} from "../../../src/facets/account/claim/SuperchainClaimingFacet.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";
import {console} from "forge-std/console.sol";

contract VelodromeRootDeploy is PortfolioFactoryConfigDeploy {
    address public constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // OP USDC
    address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address public constant VOTING_ESCROW = 0xFAf8FD17D9840595845582fCB047DF13f006787d; // Velodrome veVELO
    address public constant VOTER = 0x41C914ee0c7E1A5edCD0295623e6dC557B5aBf3C; // Velodrome Voter
    address public constant REWARDS_DISTRIBUTOR = 0x9D4736EC60715e71aFe72973f7885DCBC21EA99b; // Velodrome RewardsDistributor
    address public constant VELODROME_ROOT_POOL_FACTORY_V2 = 0x31832f2a97Fd20664D76Cc421207669b55CE4BC0;
    address public constant VELODROME_ROOT_POOL_FACTORY_CL = 0x04625B046C69577EfC40e6c0Bb83CDBAfab5a55F;
    PortfolioManager public _portfolioManager;
    PortfolioFactory public _portfolioFactory;
    address public _loanContract;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        PortfolioManager portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);
        address portfolioFactory = portfolioManager.factoryBySalt(keccak256(abi.encodePacked("velodrome-usdc")));
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

        RootPoolVotingConfig votingConfigImpl = new RootPoolVotingConfig();
        RootPoolVotingConfig votingConfig = RootPoolVotingConfig(
            address(new ERC1967Proxy(
                address(votingConfigImpl),
                abi.encodeCall(VotingConfig.initialize, (DEPLOYER_ADDRESS))
            ))
        );

        // Seed Velodrome OP root-pool factories (V2 + CL)
        votingConfig.setRootPoolFactory(VELODROME_ROOT_POOL_FACTORY_V2, true);
        votingConfig.setRootPoolFactory(VELODROME_ROOT_POOL_FACTORY_CL, true);

        SwapConfig swapConfig = _deploySwapConfig(DEPLOYER_ADDRESS);

        // Link configs on the new PortfolioFactoryConfig (deployer is owner of these)
        portfolioFactoryConfig.setVoteConfig(address(votingConfig));
        portfolioFactoryConfig.setLoanConfig(address(loanConfig));

        // Transfer ownership of every freshly-deployed config to the multisig
        loanConfig.transferOwnership(MULTISIG_ADDRESS);
        votingConfig.transferOwnership(MULTISIG_ADDRESS);
        swapConfig.transferOwnership(MULTISIG_ADDRESS);
        portfolioFactoryConfig.transferOwnership(MULTISIG_ADDRESS);

        console.log("Deployed PortfolioFactoryConfig at:", address(portfolioFactoryConfig));
        console.log("Deployed LoanConfig at:", address(loanConfig));
        console.log("Deployed RootPoolVotingConfig at:", address(votingConfig));
        console.log("Deployed SwapConfig at:", address(swapConfig));
    }

}

contract VelodromeLeafDeploy is PortfolioFactoryConfigDeploy {
    address public constant USDC = 0x2D270e6886d130D724215A266106e6832161EAEd; // INK USDC
    address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address public constant VELODROME_PM = PORTFOLIO_MANAGER_ADDRESS;

    PortfolioManager public _portfolioManager;
    PortfolioFactory public _portfolioFactory;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    // only deploy the swap and bridge facets
    function _deploy() internal {
        _portfolioManager = PortfolioManager(VELODROME_PM);
        address portfolioFactory = _portfolioManager.factoryBySalt(keccak256(abi.encodePacked("velodrome-usdc")));
        FacetRegistry facetRegistry = PortfolioFactory(portfolioFactory).facetRegistry();

        // // Get existing BridgeFacet address from registry
        address existingBridgeFacet = facetRegistry.getFacetForSelector(BridgeFacet.bridge.selector);
        // require(existingBridgeFacet != address(0), "BridgeFacet not found");

        // // Remove then re-register with expanded selectors (same facet address)
        // facetRegistry.removeFacet(existingBridgeFacet);

        // bytes4[] memory bridgeSelectors = new bytes4[](6);
        // bridgeSelectors[0] = BridgeFacet.bridge.selector;
        // bridgeSelectors[1] = BridgeFacet.swapMultiple.selector;
        // bridgeSelectors[2] = bytes4(keccak256("_token()"));
        // bridgeSelectors[3] = bytes4(keccak256("_tokenMessenger()"));
        // bridgeSelectors[4] = bytes4(keccak256("_destinationDomain()"));
        // bridgeSelectors[5] = bytes4(keccak256("_swapConfig()"));
        // facetRegistry.registerFacet(existingBridgeFacet, bridgeSelectors, "BridgeFacet");

        // Approve swap target on the SwapConfig used by BridgeFacet
        SwapConfig swapConfig = BridgeFacet(existingBridgeFacet)._swapConfig();
        swapConfig.setApprovedSwapTarget(0x0000000000001fF3684f28c67538d4D072C22734, true);
    }
}



contract VelodromeRootUpgrade is PortfolioFactoryConfigDeploy {
    address public constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // OP USDC
    address public constant VOTING_ESCROW = 0xFAf8FD17D9840595845582fCB047DF13f006787d; // Velodrome veVELO
    address public constant VOTER = 0x41C914ee0c7E1A5edCD0295623e6dC557B5aBf3C; // Velodrome Voter
    address public constant REWARDS_DISTRIBUTOR = 0x9D4736EC60715e71aFe72973f7885DCBC21EA99b; // Velodrome RewardsDistributor
    address public constant VELODROME_PM = PORTFOLIO_MANAGER_ADDRESS;

    PortfolioManager public _portfolioManager;
    PortfolioFactory public _portfolioFactory;
    address public _loanContract;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        upgradeFacets();
        vm.stopBroadcast();
    }

    function upgradeFacets() internal {
        PortfolioManager portfolioManager = PortfolioManager(VELODROME_PM);


        address portfolioFactory = portfolioManager.factoryBySalt(keccak256(abi.encodePacked("velodrome-usdc")));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        PortfolioFactoryConfig portfolioFactoryConfig = PortfolioFactory(portfolioFactory).portfolioFactoryConfig();
        SuperchainVotingConfig votingConfig = SuperchainVotingConfig(portfolioFactoryConfig.getVoteConfig());
        address loanConfig = address(portfolioFactoryConfig.getLoanConfig());
        SwapConfig swapConfig = SwapConfig(OP_SWAP_CONFIG);
        FacetRegistry facetRegistry = PortfolioFactory(portfolioFactory).facetRegistry();

        Vault vault = Vault(ILoan(portfolioFactoryConfig.getLoanContract())._vault());

        // ============================================================
        // Facet upgrades for: getLoanUtilization, decreaseTotalDebt fix,
        // mergeInternal toToken listing guard
        // ============================================================

        // 1. CollateralFacet - adds getLoanUtilization, carries decreaseTotalDebt fix via CollateralManager library
        // CollateralFacet collateralFacet = new CollateralFacet(address(portfolioFactory), VOTING_ESCROW);
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
        // collateralSelectors[10] = BaseCollateralFacet.getLoanUtilization.selector;
        // _registerFacet(facetRegistry, address(collateralFacet), collateralSelectors, "CollateralFacet");

        // 2. LendingFacet - carries decreaseTotalDebt fix via CollateralManager library
        // LendingFacet lendingFacet = new LendingFacet(address(portfolioFactory), USDC);
        // bytes4[] memory lendingSelectors = new bytes4[](4);
        // lendingSelectors[0] = BaseLendingFacet.borrow.selector;
        // lendingSelectors[1] = BaseLendingFacet.pay.selector;
        // lendingSelectors[2] = BaseLendingFacet.setTopUp.selector;
        // lendingSelectors[3] = BaseLendingFacet.borrowTo.selector;
        // _registerFacet(facetRegistry, address(lendingFacet), lendingSelectors, "LendingFacet");

        // 3. VotingEscrowFacet - mergeInternal toToken listing guard
        // VotingEscrowFacet votingEscrowFacet = new VotingEscrowFacet(address(portfolioFactory), VOTING_ESCROW, VOTER);
        // bytes4[] memory votingEscrowSelectors = new bytes4[](5);
        // votingEscrowSelectors[0] = VotingEscrowFacet.increaseLock.selector;
        // votingEscrowSelectors[1] = VotingEscrowFacet.createLock.selector;
        // votingEscrowSelectors[2] = VotingEscrowFacet.merge.selector;
        // votingEscrowSelectors[3] = VotingEscrowFacet.onERC721Received.selector;
        // votingEscrowSelectors[4] = VotingEscrowFacet.mergeInternal.selector;
        // _registerFacet(facetRegistry, address(votingEscrowFacet), votingEscrowSelectors, "VotingEscrowFacet");

        // ============================================================
        // Unchanged facets (commented out):
        // ============================================================

        // // Deploy RewardsProcessingFacet
        // RewardsProcessingFacet rewardsProcessingFacet = new VotingEscrowRewardsProcessingFacet(address(portfolioFactory), address(swapConfig), VOTING_ESCROW, address(vault), IVotingEscrow(VOTING_ESCROW).token());
        // bytes4[] memory rewardsProcessingSelectors = new bytes4[](5);
        // rewardsProcessingSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        // rewardsProcessingSelectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        // rewardsProcessingSelectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        // rewardsProcessingSelectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        // rewardsProcessingSelectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        // _registerFacet(facetRegistry, address(rewardsProcessingFacet), rewardsProcessingSelectors, "RewardsProcessingFacet");
        // // Deploy RewardsConfigFacet
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
        // ClaimingFacet claimingFacet = new ClaimingFacet(address(portfolioFactory), VOTING_ESCROW, VOTER, REWARDS_DISTRIBUTOR, address(loanConfig), address(swapConfig), address(vault));
        // bytes4[] memory claimingSelectors = new bytes4[](3);
        // claimingSelectors[0] = ClaimingFacet.claimFees.selector;
        // claimingSelectors[1] = ClaimingFacet.claimRebase.selector;
        // claimingSelectors[2] = ClaimingFacet.claimLaunchpadToken.selector;
        // _registerFacet(facetRegistry, address(claimingFacet), claimingSelectors, "ClaimingFacet");

        // // Deploy LendingFacet
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

        // // Deploy MarketplaceFacet
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


        // // Deploy SuperchainVotingFacet
        SuperchainVotingFacet votingFacet = new SuperchainVotingFacet(address(portfolioFactory), address(votingConfig), VOTING_ESCROW, VOTER);
        bytes4[] memory votingSelectors = new bytes4[](8);
        votingSelectors[0] = SuperchainVotingFacet.vote.selector;
        votingSelectors[1] = VotingFacet.voteForLaunchpadToken.selector;
        votingSelectors[2] = VotingFacet.setVotingMode.selector;
        votingSelectors[3] = VotingFacet.isManualVoting.selector;
        votingSelectors[4] = VotingFacet.defaultVote.selector;
        votingSelectors[5] = VotingFacet.batchVote.selector;
        votingSelectors[6] = VotingFacet.batchVoteForLaunchpadToken.selector;
        votingSelectors[7] = VotingFacet.isElligibleForManualVoting.selector;
        _registerFacet(facetRegistry, address(votingFacet), votingSelectors, "VotingFacet");

        // Deploy SuperchainClaimingFacet
        SuperchainClaimingFacet superchainClaimingFacet = new SuperchainClaimingFacet();
        bytes4[] memory superchainClaimingSelectors = new bytes4[](1);
        superchainClaimingSelectors[0] = SuperchainClaimingFacet.claimSuperchainRewards.selector;
        _registerFacet(facetRegistry, address(superchainClaimingFacet), superchainClaimingSelectors, "SuperchainClaimingFacet");

        // // Deploy VotingEscrowFacet
        // VotingEscrowFacet votingEscrowFacet = new VotingEscrowFacet(address(portfolioFactory), VOTING_ESCROW, VOTER);
        // bytes4[] memory votingEscrowSelectors = new bytes4[](5);
        // votingEscrowSelectors[0] = VotingEscrowFacet.increaseLock.selector;
        // votingEscrowSelectors[1] = VotingEscrowFacet.createLock.selector;
        // votingEscrowSelectors[2] = VotingEscrowFacet.merge.selector;
        // votingEscrowSelectors[3] = VotingEscrowFacet.onERC721Received.selector;
        // votingEscrowSelectors[4] = VotingEscrowFacet.mergeInternal.selector;
        // _registerFacet(facetRegistry, address(votingEscrowFacet), votingEscrowSelectors, "VotingEscrowFacet");

        // // // Upgrade Loan Contract
        // LoanV2 loanImplementation = new LoanV2();
        // LoanV2(address(portfolioFactoryConfig.getLoanContract())).upgradeToAndCall(address(loanImplementation), new bytes(0));

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

// forge script script/portfolio_account/velodrome/DeployVelodrome.s.sol:VelodromeRootDeploy --chain-id 10 --rpc-url $OP_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/velodrome/DeployVelodrome.s.sol:VelodromeLeafDeploy --chain-id 10 --rpc-url $OP_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/velodrome/DeployVelodrome.s.sol:VelodromeRootUpgrade --chain-id 10 --rpc-url $OP_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/velodrome/DeployVelodrome.s.sol:VelodromeRootPoolVotingMigrate --chain-id 10 --rpc-url $OP_RPC_URL --broadcast --verify --via-ir

// forge script script/portfolio_account/velodrome/DeployVelodrome.s.sol:VelodromeLeafDeploy \
//     --chain-id 57073 \
//     --rpc-url $INK_RPC_URL \
//     --broadcast \
//     --verify \
//     --via-ir
