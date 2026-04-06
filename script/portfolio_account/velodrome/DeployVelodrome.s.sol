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
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {SuperchainVotingFacet} from "../../../src/facets/account/vote/SuperchainVoting.sol";
import {SuperchainVotingConfig} from "../../../src/facets/account/config/SuperchainVotingConfig.sol";
import {SuperchainClaimingFacet} from "../../../src/facets/account/claim/SuperchainClaimingFacet.sol";
import {console} from "forge-std/console.sol";

contract VelodromeRootDeploy is PortfolioFactoryConfigDeploy {
    address public constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85; // OP USDC
    address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address public constant VOTING_ESCROW = 0xFAf8FD17D9840595845582fCB047DF13f006787d; // Velodrome veAERO
    address public constant VOTER = 0x41C914ee0c7E1A5edCD0295623e6dC557B5aBf3C; // Velodrome Voter
    address public constant REWARDS_DISTRIBUTOR = 0x9D4736EC60715e71aFe72973f7885DCBC21EA99b; // Velodrome RewardsDistributor

    PortfolioManager public _portfolioManager;
    PortfolioFactory public _portfolioFactory;
    address public _loanContract;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        _portfolioManager = new PortfolioManager{salt: SALT}(DEPLOYER_ADDRESS);
        require(address(_portfolioManager) == address(0x5f3736D7686edb3F74c0726D8fDF3f58252cC1F9), "Unexpected PortfolioManager address");
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _portfolioManager.deployFactory(bytes32(keccak256(abi.encodePacked("velodrome-usdc"))));
        
        // Use inherited _deploy() function from PortfolioFactoryConfigDeploy
        (PortfolioFactoryConfig portfolioFactoryConfig, VotingConfig votingConfig, LoanConfig loanConfig, SwapConfig swapConfig) = PortfolioFactoryConfigDeploy._deploy(false, address(portfolioFactory));

        // Set configs at script level - these calls will be broadcast from deployer
        portfolioFactoryConfig.setVoteConfig(address(votingConfig));
        portfolioFactoryConfig.setLoanConfig(address(loanConfig));

        _portfolioFactory = portfolioFactory;

        // Deploy fresh Loan contract
        Loan loanImplementation = new Loan();
        ERC1967Proxy loanProxy = new ERC1967Proxy(address(loanImplementation), "");
        _loanContract = address(loanProxy);

        // Create vault before deploying facets (needed for ClaimingFacet and RewardsProcessingFacet)
        Vault vaultImplementation = new Vault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        Vault vault = Vault(address(vaultProxy));
        
        // Initialize vault
        vault.initialize(address(USDC), address(_loanContract), "40op-USDC-VAULT", "40op-USDC-VAULT");
        
        // Initialize loan
        Loan(address(_loanContract)).initialize(address(vault), USDC);
        LoanV2 loanV2 = new LoanV2();
        LoanV2(address(_loanContract)).upgradeToAndCall(address(loanV2), new bytes(0));
        LoanV2(address(_loanContract)).setMultiplier(52);
        LoanV2(address(_loanContract)).setRewardsRate(400);
        LoanV2(address(_loanContract)).setPortfolioFactory(address(portfolioFactory));
        
        portfolioFactoryConfig.setLoanContract(address(_loanContract));
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));
        
        // Deploy ClaimingFacet
        ClaimingFacet claimingFacet = new ClaimingFacet(address(portfolioFactory), VOTING_ESCROW, VOTER, REWARDS_DISTRIBUTOR, address(loanConfig), address(swapConfig), address(vault));
        bytes4[] memory claimingSelectors = new bytes4[](3);
        claimingSelectors[0] = ClaimingFacet.claimFees.selector;
        claimingSelectors[1] = ClaimingFacet.claimRebase.selector;
        claimingSelectors[2] = ClaimingFacet.claimLaunchpadToken.selector;
        _registerFacet(facetRegistry, address(claimingFacet), claimingSelectors, "ClaimingFacet");
        
        // Deploy CollateralFacet
        CollateralFacet collateralFacet = new CollateralFacet(address(portfolioFactory), VOTING_ESCROW);
        bytes4[] memory collateralSelectors = new bytes4[](8);
        collateralSelectors[0] = BaseCollateralFacet.addCollateral.selector;
        collateralSelectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        collateralSelectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        collateralSelectors[3] = BaseCollateralFacet.getMaxLoan.selector;
        collateralSelectors[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        collateralSelectors[5] = BaseCollateralFacet.removeCollateral.selector;
        collateralSelectors[6] = BaseCollateralFacet.getCollateralToken.selector;
        collateralSelectors[7] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        _registerFacet(facetRegistry, address(collateralFacet), collateralSelectors, "CollateralFacet");

        // Deploy LendingFacet
        LendingFacet lendingFacet = new LendingFacet(address(portfolioFactory), USDC);
        bytes4[] memory lendingSelectors = new bytes4[](4);
        lendingSelectors[0] = BaseLendingFacet.borrow.selector;
        lendingSelectors[1] = BaseLendingFacet.pay.selector;
        lendingSelectors[2] = BaseLendingFacet.setTopUp.selector;
        lendingSelectors[3] = BaseLendingFacet.topUp.selector;
        _registerFacet(facetRegistry, address(lendingFacet), lendingSelectors, "LendingFacet");

        // Deploy VotingFacet
        SuperchainVotingFacet votingFacet = new SuperchainVotingFacet(address(portfolioFactory), address(votingConfig), VOTING_ESCROW, VOTER);
        bytes4[] memory votingSelectors = new bytes4[](5);
        votingSelectors[0] = SuperchainVotingFacet.vote.selector;
        votingSelectors[1] = VotingFacet.voteForLaunchpadToken.selector;
        votingSelectors[2] = VotingFacet.setVotingMode.selector;
        votingSelectors[3] = VotingFacet.isManualVoting.selector;
        votingSelectors[4] = VotingFacet.defaultVote.selector;
        _registerFacet(facetRegistry, address(votingFacet), votingSelectors, "VotingFacet");

        // Deploy VotingEscrowFacet
        // Get PortfolioFactory from PortfolioManager

        VotingEscrowFacet votingEscrowFacet = new VotingEscrowFacet(address(portfolioFactory), VOTING_ESCROW, VOTER);
        bytes4[] memory votingEscrowSelectors = new bytes4[](4);
        votingEscrowSelectors[0] = VotingEscrowFacet.increaseLock.selector;
        votingEscrowSelectors[1] = VotingEscrowFacet.createLock.selector;
        votingEscrowSelectors[2] = VotingEscrowFacet.merge.selector;
        votingEscrowSelectors[3] = VotingEscrowFacet.onERC721Received.selector;
        _registerFacet(facetRegistry, address(votingEscrowFacet), votingEscrowSelectors, "VotingEscrowFacet");

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
        PortfolioMarketplace portfolioMarketplace = new PortfolioMarketplace(address(_portfolioManager), address(VOTING_ESCROW), 100, DEPLOYER_ADDRESS);
        MarketplaceFacet marketplaceFacet = new MarketplaceFacet(address(portfolioFactory), VOTING_ESCROW, address(portfolioMarketplace));
        bytes4[] memory marketplaceSelectors = new bytes4[](8);
        marketplaceSelectors[0] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        marketplaceSelectors[1] = BaseMarketplaceFacet.makeListing.selector;
        marketplaceSelectors[2] = BaseMarketplaceFacet.cancelListing.selector;
        marketplaceSelectors[3] = BaseMarketplaceFacet.marketplace.selector;
        marketplaceSelectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        marketplaceSelectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        marketplaceSelectors[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
        marketplaceSelectors[7] = BaseMarketplaceFacet.isListingPurchasable.selector;
        _registerFacet(facetRegistry, address(marketplaceFacet), marketplaceSelectors, "MarketplaceFacet");

        // Deploy RewardsProcessingFacet
        RewardsProcessingFacet rewardsProcessingFacet = new VotingEscrowRewardsProcessingFacet(address(portfolioFactory), address(swapConfig), VOTING_ESCROW, address(vault), IVotingEscrow(VOTING_ESCROW).token());
        bytes4[] memory rewardsProcessingSelectors = new bytes4[](5);
        rewardsProcessingSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        rewardsProcessingSelectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        rewardsProcessingSelectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        rewardsProcessingSelectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        rewardsProcessingSelectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        _registerFacet(facetRegistry, address(rewardsProcessingFacet), rewardsProcessingSelectors, "RewardsProcessingFacet");

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

contract VelodromeLeafDeploy is PortfolioFactoryConfigDeploy {
    address public constant USDC = 0x2D270e6886d130D724215A266106e6832161EAEd; // INK USDC
    address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;

    PortfolioManager public _portfolioManager;
    PortfolioFactory public _portfolioFactory;
    
    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    // Register extra selectors on existing BridgeFacet
    function _deploy() internal {
        _portfolioManager = PortfolioManager(0x5f3736D7686edb3F74c0726D8fDF3f58252cC1F9);
        address portfolioFactory = _portfolioManager.factoryBySalt(keccak256(abi.encodePacked("velodrome-usdc")));
        FacetRegistry facetRegistry = PortfolioFactory(portfolioFactory).facetRegistry();
        // _portfolioFactory = PortfolioFactory(portfolioFactory);

        // // Get existing BridgeFacet address from registry
        address existingBridgeFacet = facetRegistry.getFacetForSelector(BridgeFacet.bridge.selector);
        // require(existingBridgeFacet != address(0), "BridgeFacet not found");

        // // Remove then re-register with expanded selectors (same facet address)
        // facetRegistry.removeFacet(existingBridgeFacet);

        // bytes4[] memory bridgeSelectors = new bytes4[](6);
        // bridgeSelectors[0] = BridgeFacet.bridge.selector;
        // bridgeSelectors[1] = BridgeFacet.swapAndBridge.selector;
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
    address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address public constant VOTING_ESCROW = 0xFAf8FD17D9840595845582fCB047DF13f006787d; // Velodrome veAERO
    address public constant VOTER = 0x41C914ee0c7E1A5edCD0295623e6dC557B5aBf3C; // Velodrome Voter
    address public constant REWARDS_DISTRIBUTOR = 0x9D4736EC60715e71aFe72973f7885DCBC21EA99b; // Velodrome RewardsDistributor

    PortfolioManager public _portfolioManager = PortfolioManager(0x5f3736D7686edb3F74c0726D8fDF3f58252cC1F9);
    PortfolioFactory public _portfolioFactory;
    address public _loanContract;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        upgradeFacets();
        vm.stopBroadcast();
    }

    function upgradeFacets() internal {
        PortfolioManager portfolioManager = PortfolioManager(0x5f3736D7686edb3F74c0726D8fDF3f58252cC1F9);

        address portfolioFactory = portfolioManager.factoryBySalt(keccak256(abi.encodePacked("velodrome-usdc")));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        PortfolioFactoryConfig portfolioFactoryConfig = PortfolioFactory(portfolioFactory).portfolioFactoryConfig();
        SuperchainVotingConfig votingConfig = SuperchainVotingConfig(portfolioFactoryConfig.getVoteConfig());
        address loanConfig = address(portfolioFactoryConfig.getLoanConfig());
        FacetRegistry facetRegistry = PortfolioFactory(portfolioFactory).facetRegistry();

        Vault vault = Vault(ILoan(portfolioFactoryConfig.getLoanContract())._vault());


        // // // Deploy RewardsProcessingFacet
        // RewardsProcessingFacet rewardsProcessingFacet = new VotingEscrowRewardsProcessingFacet(address(portfolioFactory), address(swapConfig), VOTING_ESCROW, address(vault), IVotingEscrow(VOTING_ESCROW).token());
        // bytes4[] memory rewardsProcessingSelectors = new bytes4[](5);
        // rewardsProcessingSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        // rewardsProcessingSelectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        // rewardsProcessingSelectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        // rewardsProcessingSelectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        // rewardsProcessingSelectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        // _registerFacet(facetRegistry, address(rewardsProcessingFacet), rewardsProcessingSelectors, "RewardsProcessingFacet");
        //
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

        // // // Deploy LendingFacet
        // LendingFacet lendingFacet = new LendingFacet(address(portfolioFactory), USDC);
        // bytes4[] memory lendingSelectors = new bytes4[](4);
        // lendingSelectors[0] = BaseLendingFacet.borrow.selector;
        // lendingSelectors[1] = BaseLendingFacet.pay.selector;
        // lendingSelectors[2] = BaseLendingFacet.setTopUp.selector;
        // lendingSelectors[3] = BaseLendingFacet.topUp.selector;
        // _registerFacet(facetRegistry, address(lendingFacet), lendingSelectors, "LendingFacet");

        // // // Deploy MarketplaceFacet
        // PortfolioMarketplace portfolioMarketplace = new PortfolioMarketplace(address(_portfolioManager), address(VOTING_ESCROW), 100, DEPLOYER_ADDRESS);
        // MarketplaceFacet marketplaceFacet = new MarketplaceFacet(address(portfolioFactory), VOTING_ESCROW, address(portfolioMarketplace));
        // console.log("PortfolioMarketplace deployed at:", address(portfolioMarketplace));
        // bytes4[] memory marketplaceSelectors = new bytes4[](7);
        // marketplaceSelectors[0] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        // marketplaceSelectors[1] = BaseMarketplaceFacet.makeListing.selector;
        // marketplaceSelectors[2] = BaseMarketplaceFacet.cancelListing.selector;
        // marketplaceSelectors[3] = BaseMarketplaceFacet.marketplace.selector;
        // marketplaceSelectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        // marketplaceSelectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        // marketplaceSelectors[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
        // _registerFacet(facetRegistry, address(marketplaceFacet), marketplaceSelectors, "MarketplaceFacet");


        // SuperchainVotingFacet votingFacet = new SuperchainVotingFacet(address(portfolioFactory), address(votingConfig), VOTING_ESCROW, VOTER);
        // bytes4[] memory votingSelectors = new bytes4[](5);
        // votingSelectors[0] = SuperchainVotingFacet.vote.selector;
        // votingSelectors[1] = VotingFacet.voteForLaunchpadToken.selector;
        // votingSelectors[2] = VotingFacet.setVotingMode.selector;
        // votingSelectors[3] = VotingFacet.isManualVoting.selector;
        // votingSelectors[4] = VotingFacet.defaultVote.selector;
        // _registerFacet(facetRegistry, address(votingFacet), votingSelectors, "VotingFacet");

        // Deploy SuperchainClaimingFacet
        SuperchainClaimingFacet superchainClaimingFacet = new SuperchainClaimingFacet();
        bytes4[] memory superchainClaimingSelectors = new bytes4[](1);
        superchainClaimingSelectors[0] = SuperchainClaimingFacet.claimSuperchainRewards.selector;
        _registerFacet(facetRegistry, address(superchainClaimingFacet), superchainClaimingSelectors, "SuperchainClaimingFacet");

        // // // Deploy VotingEscrowFacet
        // VotingEscrowFacet votingEscrowFacet = new VotingEscrowFacet(address(portfolioFactory), VOTING_ESCROW, VOTER);
        // bytes4[] memory votingEscrowSelectors = new bytes4[](3);
        // votingEscrowSelectors[0] = VotingEscrowFacet.increaseLock.selector;
        // votingEscrowSelectors[1] = VotingEscrowFacet.createLock.selector;
        // votingEscrowSelectors[2] = VotingEscrowFacet.merge.selector;
        // _registerFacet(facetRegistry, address(votingEscrowFacet), votingEscrowSelectors, "VotingEscrowFacet");

        // // Deploy CollateralFacet
        // CollateralFacet collateralFacet = new CollateralFacet(address(portfolioFactory), address(portfolioFactoryConfig), VOTING_ESCROW);
        // bytes4[] memory collateralSelectors = new bytes4[](8);
        // collateralSelectors[0] = BaseCollateralFacet.addCollateral.selector;
        // collateralSelectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        // collateralSelectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        // collateralSelectors[3] = BaseCollateralFacet.getMaxLoan.selector;
        // collateralSelectors[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        // collateralSelectors[5] = BaseCollateralFacet.removeCollateral.selector;
        // collateralSelectors[6] = BaseCollateralFacet.getCollateralToken.selector;
        // collateralSelectors[7] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        // _registerFacet(facetRegistry, address(collateralFacet), collateralSelectors, "CollateralFacet");


        // // Upgrade Loan Contract
        // Loan loanImplementation = new Loan();
        // Loan(address(portfolioFactoryConfig.getLoanContract())).upgradeToAndCall(address(loanImplementation), new bytes(0));
    }
}
// forge script script/portfolio_account/velodrome/DeployVelodrome.s.sol:VelodromeRootDeploy --chain-id 10 --rpc-url $OP_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/velodrome/DeployVelodrome.s.sol:VelodromeLeafDeploy --chain-id 10 --rpc-url $OP_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/velodrome/DeployVelodrome.s.sol:VelodromeRootUpgrade --chain-id 10 --rpc-url $OP_RPC_URL --broadcast --verify --via-ir


// forge script script/portfolio_account/velodrome/DeployVelodrome.s.sol:VelodromeLeafDeploy \
//     --chain-id 57073 \
//     --rpc-url $INK_RPC_URL \
//     --broadcast \
//     --verify \
//     --via-ir
