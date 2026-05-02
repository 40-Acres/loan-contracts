// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {PortfolioFactoryConfigDeploy} from "../DeployPortfolioFactoryConfig.s.sol";

import {ClaimingFacet} from "../../../src/facets/account/claim/ClaimingFacet.sol";
import {BlackholeClaimingFacet} from "../../../src/facets/account/blackhole/BlackholeClaimingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BlackholeCollateralFacet} from "../../../src/facets/account/blackhole/BlackholeCollateralFacet.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";
import {BlackholeVotingEscrowFacet} from "../../../src/facets/account/blackhole/BlackholeVotingEscrowFacet.sol";
import {MigrationFacet} from "../../../src/facets/account/migration/MigrationFacet.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {BlackholeRewardsProcessingFacet} from "../../../src/facets/account/blackhole/BlackholeRewardsProcessingFacet.sol";
import {BlackholeMarketplaceFacet} from "../../../src/facets/account/blackhole/BlackholeMarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../src/facets/marketplace/PortfolioMarketplace.sol";
import {Loan} from "../../../src/Loan.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";
import {Vault} from "../../../src/VaultV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IMigrationFacet} from "../../../src/facets/account/migration/IMigrationFacet.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";

contract SuperNovaRootDeploy is PortfolioFactoryConfigDeploy {
    // SuperNova / Ethereum Mainnet addresses
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // Ethereum USDC
    address public constant VOTING_ESCROW = 0x4C3e7640B3e3A39a2e5d030A0C1412d80FEE1D44; // veNOVA
    address public constant VOTER = 0x1c7BF2532dfa34eeea02C3759E0ca8D87B1D8171; // SuperNova VoterV3
    address public constant GAUGE_MANAGER = 0x19a410046Afc4203AEcE5fbFc7A6Ac1a4F517AE2; // SuperNova GaugeManager (fee/bribe claims)
    address public constant REWARDS_DISTRIBUTOR = 0xB3410A30af5033aF822B8eA5Ad3bd0a19490ea97; // SuperNova RewardsDistributor
    address public constant SNOVA_TOKEN = 0x00Da8466B296E382E5Da2Bf20962D0cB87200c78; // NOVA token

    PortfolioManager public _portfolioManager;
    PortfolioFactory public _portfolioFactory;
    address public _loanContract;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        PortfolioManager _portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);
        address portfolioFactory = _portfolioManager.factoryBySalt(keccak256(abi.encodePacked("supernova")));
        require(portfolioFactory != address(0), "SuperNova factory not deployed");
        FacetRegistry facetRegistry = PortfolioFactory(portfolioFactory).facetRegistry();
        PortfolioFactoryConfig portfolioFactoryConfig = PortfolioFactoryConfig(PortfolioFactory(portfolioFactory).portfolioFactoryConfig());

        SwapConfig swapConfig = SwapConfig(address(0xD504Da3Ae86Aa3233871dbc8ae3Eb38824138F7C));

        address loanConfig = address(portfolioFactoryConfig.getLoanConfig());
        address votingConfig = portfolioFactoryConfig.getVoteConfig();

        _portfolioFactory = PortfolioFactory(portfolioFactory);

        console.log("Deployed SuperNova PortfolioFactory at:", portfolioFactory);
        // setPortfolioFactoryConfig must be called by multisig (PM owner)
        console.log("=== Multisig Action Required ===");
        console.log("Call PortfolioFactory.setPortfolioFactoryConfig with:");
        console.log("  PortfolioFactory:", portfolioFactory);
        console.log("  PortfolioFactoryConfig:", address(portfolioFactoryConfig));

        // BlackholeClaimingFacet claimingFacet = new BlackholeClaimingFacet(address(portfolioFactory), VOTING_ESCROW, VOTER, GAUGE_MANAGER, REWARDS_DISTRIBUTOR, address(0), loanConfig, address(swapConfig), address(0));
        // bytes4[] memory claimingSelectors = new bytes4[](3);
        // claimingSelectors[0] = ClaimingFacet.claimFees.selector;
        // claimingSelectors[1] = ClaimingFacet.claimRebase.selector;
        // claimingSelectors[2] = ClaimingFacet.claimLaunchpadToken.selector;
        // _registerFacet(facetRegistry, address(claimingFacet), claimingSelectors, "ClaimingFacet");

        // Deploy BlackholeCollateralFacet (auto-resets voter attachments in removeCollateral)
        BlackholeCollateralFacet collateralFacet = new BlackholeCollateralFacet(address(portfolioFactory), VOTING_ESCROW, VOTER);
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
        collateralSelectors[10] = BaseCollateralFacet.getLoanUtilization.selector;
        _registerFacet(facetRegistry, address(collateralFacet), collateralSelectors, "CollateralFacet");

        // Deploy VotingFacet
        // VotingFacet votingFacet = new VotingFacet(address(portfolioFactory), address(votingConfig), VOTING_ESCROW, VOTER);
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

        // Deploy BlackholeVotingEscrowFacet (shared with Blackhole — handles increase_amount/create_lock_for)
        // BlackholeVotingEscrowFacet votingEscrowFacet = new BlackholeVotingEscrowFacet(address(portfolioFactory), VOTING_ESCROW, VOTER);
        // bytes4[] memory votingEscrowSelectors = new bytes4[](6);
        // votingEscrowSelectors[0] = BlackholeVotingEscrowFacet.increaseLock.selector;
        // votingEscrowSelectors[1] = BlackholeVotingEscrowFacet.createLock.selector;
        // votingEscrowSelectors[2] = BlackholeVotingEscrowFacet.merge.selector;
        // votingEscrowSelectors[3] = BlackholeVotingEscrowFacet.onERC721Received.selector;
        // votingEscrowSelectors[4] = BlackholeVotingEscrowFacet.mergeInternal.selector;
        // votingEscrowSelectors[5] = BlackholeVotingEscrowFacet.reset.selector;
        // _registerFacet(facetRegistry, address(votingEscrowFacet), votingEscrowSelectors, "VotingEscrowFacet");

        // Deploy BlackholeRewardsProcessingFacet (shared — handles increase_amount for lock increase)
        // RewardsProcessingFacet rewardsProcessingFacet = new BlackholeRewardsProcessingFacet(address(portfolioFactory), address(swapConfig), VOTING_ESCROW, address(0), USDC);
        // bytes4[] memory rewardsProcessingSelectors = new bytes4[](5);
        // rewardsProcessingSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        // rewardsProcessingSelectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        // rewardsProcessingSelectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        // rewardsProcessingSelectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        // rewardsProcessingSelectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        // _registerFacet(facetRegistry, address(rewardsProcessingFacet), rewardsProcessingSelectors, "RewardsProcessingFacet");

        // Deploy RewardsConfigFacet
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

        // Deploy PortfolioMarketplace (veNOVA marketplace)
        // BlackholeMarketplaceFacet marketplaceFacet = new BlackholeMarketplaceFacet(address(portfolioFactory), VOTING_ESCROW, address(VENOVA_MARKETPLACE), VOTER);
        // bytes4[] memory marketplaceSelectors = new bytes4[](8);
        // marketplaceSelectors[0] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        // marketplaceSelectors[1] = BaseMarketplaceFacet.makeListing.selector;
        // marketplaceSelectors[2] = BaseMarketplaceFacet.cancelListing.selector;
        // marketplaceSelectors[3] = BaseMarketplaceFacet.marketplace.selector;
        // marketplaceSelectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        // marketplaceSelectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        // marketplaceSelectors[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
        // marketplaceSelectors[7] = BaseMarketplaceFacet.isListingPurchasable.selector;
        // _registerFacet(facetRegistry, address(marketplaceFacet), marketplaceSelectors, "MarketplaceFacet");

        // transfer ownerships to multisig
        // votingConfig.transferOwnership(MULTISIG_ADDRESS);
        // swapConfig.transferOwnership(MULTISIG_ADDRESS);
        // portfolioFactoryConfig.transferOwnership(MULTISIG_ADDRESS);
        // loanConfig.transferOwnership(MULTISIG_ADDRESS);
    }

}

// forge script script/portfolio_account/blackhole/DeploySuperNova.s.sol:SuperNovaRootDeploy --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
