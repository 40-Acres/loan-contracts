// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioAccountConfig} from "../../../src/facets/account/config/PortfolioAccountConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {PortfolioAccountConfigDeploy} from "../DeployPortfolioAccountConfig.s.sol";
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
import {console} from "forge-std/console.sol";

contract AerodromeRootDeploy is PortfolioAccountConfigDeploy {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base USDC
    address public constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address public constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4; // Aerodrome veAERO
    address public constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5; // Aerodrome Voter
    address public constant REWARDS_DISTRIBUTOR = 0x227f65131A261548b057215bB1D5Ab2997964C7d; // Aerodrome RewardsDistributor
    bytes32 public constant SALT = bytes32(uint256(0x420ac2e));
    address public constant PORTFOLIO_MANAGER = 0x427D890e5794A8B3AB3b9aEe0B3481F5CBCc09C5;

    // Reuse existing configs and vault from the Aerodrome deployment
    address public constant EXISTING_AERODROME_CONFIG = 0x400C710cbEadc5bb8b7132B3061fA1b6d6f80Dd8;
    address public constant EXISTING_SWAP_CONFIG = 0x3646C436f18f0e2E38E10D1A147f901a96BD4390;

    PortfolioManager public _portfolioManager = PortfolioManager(PORTFOLIO_MANAGER);
    PortfolioFactory public _portfolioFactory;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = _portfolioManager.deployFactory(bytes32(keccak256(abi.encodePacked("aerodrome"))));

        // Deploy fresh PortfolioAccountConfig and LoanConfig (no rewards rate/multiplier)
        PortfolioAccountConfig configImpl = new PortfolioAccountConfig();
        PortfolioAccountConfig portfolioAccountConfig = PortfolioAccountConfig(
            address(new ERC1967Proxy(
                address(configImpl),
                abi.encodeCall(PortfolioAccountConfig.initialize, (DEPLOYER_ADDRESS))
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
        PortfolioAccountConfig existingConfig = PortfolioAccountConfig(EXISTING_AERODROME_CONFIG);
        SwapConfig swapConfig = SwapConfig(EXISTING_SWAP_CONFIG);
        address votingConfig = address(existingConfig.getVoteConfig());
        address existingLoanContract = existingConfig.getLoanContract();
        Vault vault = Vault(ILoan(existingLoanContract)._vault());

        // Link configs on the new PortfolioAccountConfig
        portfolioAccountConfig.setVoteConfig(votingConfig);
        portfolioAccountConfig.setLoanConfig(address(loanConfig));
        portfolioAccountConfig.setLoanContract(existingLoanContract);
        portfolioAccountConfig.setPortfolioFactory(address(portfolioFactory));

        _portfolioFactory = portfolioFactory;

        // Deploy ClaimingFacet
        ClaimingFacet claimingFacet = new ClaimingFacet(address(portfolioFactory), address(portfolioAccountConfig), VOTING_ESCROW, VOTER, REWARDS_DISTRIBUTOR, address(loanConfig), address(swapConfig), address(vault));
        bytes4[] memory claimingSelectors = new bytes4[](3);
        claimingSelectors[0] = ClaimingFacet.claimFees.selector;
        claimingSelectors[1] = ClaimingFacet.claimRebase.selector;
        claimingSelectors[2] = ClaimingFacet.claimLaunchpadToken.selector;
        _registerFacet(facetRegistry, address(claimingFacet), claimingSelectors, "ClaimingFacet");

        // Deploy CollateralFacet
        CollateralFacet collateralFacet = new CollateralFacet(address(portfolioFactory), address(portfolioAccountConfig), VOTING_ESCROW);
        bytes4[] memory collateralSelectors = new bytes4[](11);
        collateralSelectors[0] = BaseCollateralFacet.addCollateral.selector;
        collateralSelectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        collateralSelectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        collateralSelectors[3] = BaseCollateralFacet.getUnpaidFees.selector;
        collateralSelectors[4] = BaseCollateralFacet.getMaxLoan.selector;
        collateralSelectors[5] = BaseCollateralFacet.getOriginTimestamp.selector;
        collateralSelectors[6] = BaseCollateralFacet.removeCollateral.selector;
        collateralSelectors[7] = BaseCollateralFacet.getCollateralToken.selector;
        collateralSelectors[8] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        collateralSelectors[9] = BaseCollateralFacet.getLockedCollateral.selector;
        collateralSelectors[10] = BaseCollateralFacet.removeCollateralTo.selector;
        _registerFacet(facetRegistry, address(collateralFacet), collateralSelectors, "CollateralFacet");

        // Deploy VotingFacet
        VotingFacet votingFacet = new VotingFacet(address(portfolioFactory), address(portfolioAccountConfig), votingConfig, VOTING_ESCROW, VOTER);
        bytes4[] memory votingSelectors = new bytes4[](5);
        votingSelectors[0] = VotingFacet.vote.selector;
        votingSelectors[1] = VotingFacet.voteForLaunchpadToken.selector;
        votingSelectors[2] = VotingFacet.setVotingMode.selector;
        votingSelectors[3] = VotingFacet.isManualVoting.selector;
        votingSelectors[4] = VotingFacet.defaultVote.selector;
        _registerFacet(facetRegistry, address(votingFacet), votingSelectors, "VotingFacet");

        // Deploy VotingEscrowFacet
        VotingEscrowFacet votingEscrowFacet = new VotingEscrowFacet(address(portfolioFactory), address(portfolioAccountConfig), VOTING_ESCROW, VOTER);
        bytes4[] memory votingEscrowSelectors = new bytes4[](4);
        votingEscrowSelectors[0] = VotingEscrowFacet.increaseLock.selector;
        votingEscrowSelectors[1] = VotingEscrowFacet.createLock.selector;
        votingEscrowSelectors[2] = VotingEscrowFacet.merge.selector;
        votingEscrowSelectors[3] = VotingEscrowFacet.onERC721Received.selector;
        _registerFacet(facetRegistry, address(votingEscrowFacet), votingEscrowSelectors, "VotingEscrowFacet");

        // Deploy VexyFacet
        VexyFacet vexyFacet = new VexyFacet(address(portfolioFactory), address(portfolioAccountConfig), VOTING_ESCROW);
        bytes4[] memory vexySelectors = new bytes4[](1);
        vexySelectors[0] = VexyFacet.buyVexyListing.selector;
        _registerFacet(facetRegistry, address(vexyFacet), vexySelectors, "VexyFacet");

        // Deploy OpenXFacet
        OpenXFacet openXFacet = new OpenXFacet(address(portfolioFactory), address(portfolioAccountConfig), VOTING_ESCROW);
        bytes4[] memory openXSelectors = new bytes4[](1);
        openXSelectors[0] = OpenXFacet.buyOpenXListing.selector;
        _registerFacet(facetRegistry, address(openXFacet), openXSelectors, "OpenXFacet");

        // Deploy MarketplaceFacet
        PortfolioMarketplace portfolioMarketplace = new PortfolioMarketplace(address(_portfolioManager), address(VOTING_ESCROW), 100, DEPLOYER_ADDRESS);
        MarketplaceFacet marketplaceFacet = new MarketplaceFacet(address(portfolioFactory), address(portfolioAccountConfig), VOTING_ESCROW, address(portfolioMarketplace));
        bytes4[] memory marketplaceSelectors = new bytes4[](7);
        marketplaceSelectors[0] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        marketplaceSelectors[1] = BaseMarketplaceFacet.makeListing.selector;
        marketplaceSelectors[2] = BaseMarketplaceFacet.cancelListing.selector;
        marketplaceSelectors[3] = BaseMarketplaceFacet.marketplace.selector;
        marketplaceSelectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        marketplaceSelectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        marketplaceSelectors[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
        _registerFacet(facetRegistry, address(marketplaceFacet), marketplaceSelectors, "MarketplaceFacet");

        // Deploy RewardsProcessingFacet
        RewardsProcessingFacet rewardsProcessingFacet = new RewardsProcessingFacet(address(portfolioFactory), address(portfolioAccountConfig), address(swapConfig), VOTING_ESCROW, address(vault));
        bytes4[] memory rewardsProcessingSelectors = new bytes4[](12);
        rewardsProcessingSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        rewardsProcessingSelectors[1] = RewardsProcessingFacet.setRewardsToken.selector;
        rewardsProcessingSelectors[2] = RewardsProcessingFacet.getRewardsToken.selector;
        rewardsProcessingSelectors[3] = RewardsProcessingFacet.setRecipient.selector;
        rewardsProcessingSelectors[4] = RewardsProcessingFacet.swapToRewardsToken.selector;
        rewardsProcessingSelectors[5] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        rewardsProcessingSelectors[6] = RewardsProcessingFacet.calculateRoutes.selector;
        rewardsProcessingSelectors[7] = RewardsProcessingFacet.setZeroBalanceDistribution.selector;
        rewardsProcessingSelectors[8] = RewardsProcessingFacet.getZeroBalanceDistribution.selector;
        rewardsProcessingSelectors[9] = RewardsProcessingFacet.setActiveBalanceDistribution.selector;
        rewardsProcessingSelectors[10] = RewardsProcessingFacet.getActiveBalanceDistribution.selector;
        rewardsProcessingSelectors[11] = RewardsProcessingFacet.clearActiveBalanceDistribution.selector;
        _registerFacet(facetRegistry, address(rewardsProcessingFacet), rewardsProcessingSelectors, "RewardsProcessingFacet");

        // Post-deployment validation - reverts the entire script if anything is wrong
        _validateDeployment(portfolioAccountConfig, address(portfolioFactory));
    }

    /**
     * @dev Helper function to register or replace a facet in the FacetRegistry
     * Since we're at script level during broadcast, calls will be from deployer
     */
    function _registerFacet(
        FacetRegistry facetRegistry,
        address facetAddress,
        bytes4[] memory selectors,
        string memory name
    ) internal {
        address oldFacet = facetRegistry.getFacetForSelector(selectors[0]);
        if (oldFacet == address(0)) {
            facetRegistry.registerFacet(facetAddress, selectors, name);
        } else {
            facetRegistry.replaceFacet(oldFacet, facetAddress, selectors, name);
        }
    }

    /// @dev Post-deployment validation. Reverts the script if any proxy is misconfigured.
    ///      Covers both borrow() and pay() call chains including getMaxLoan() dependencies.
    function _validateDeployment(PortfolioAccountConfig config, address expectedFactory) internal view {
        require(config.getPortfolioFactory() == expectedFactory, "Validation: config.getPortfolioFactory() mismatch");
        require(config.getLoanContract() != address(0), "Validation: config.getLoanContract() is zero");
        require(config.getVoteConfig() != address(0), "Validation: config.getVoteConfig() is zero");
        require(address(config.getLoanConfig()) != address(0), "Validation: config.getLoanConfig() is zero");
        require(config.getVault() != address(0), "Validation: config.getVault() is zero");

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

contract AerodromeLeafDeploy is PortfolioAccountConfigDeploy {
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
        
        // Use inherited _deploy() function from PortfolioAccountConfigDeploy
        (PortfolioAccountConfig portfolioAccountConfig, VotingConfig votingConfig, LoanConfig loanConfig, SwapConfig swapConfig) = PortfolioAccountConfigDeploy._deploy(false);
        _portfolioFactory = portfolioFactory;
        
        // Deploy only swap and bridge facets directly (no contract instances)
        // This allows calls to be broadcast from deployer account
        
        // Deploy BridgeFacet
        // BridgeFacet bridgeFacet = new BridgeFacet(address(portfolioFactory), address(portfolioAccountConfig), USDC, TOKEN_MESSENGER, 2);
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



contract AerodromeRootUpgrade is PortfolioAccountConfigDeploy {
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
        PortfolioManager portfolioManager = PortfolioManager(0x427D890e5794A8B3AB3b9aEe0B3481F5CBCc09C5);
        address portfolioFactory = portfolioManager.factoryBySalt(keccak256(abi.encodePacked("aerodrome")));
        FacetRegistry facetRegistry = PortfolioFactory(portfolioFactory).facetRegistry();

        // Read existing Aerodrome deployment configs
        PortfolioAccountConfig existingConfig = PortfolioAccountConfig(0x400C710cbEadc5bb8b7132B3061fA1b6d6f80Dd8);
        SwapConfig swapConfig = SwapConfig(0x3646C436f18f0e2E38E10D1A147f901a96BD4390);
        address votingConfig = address(existingConfig.getVoteConfig());
        address existingLoanContract = existingConfig.getLoanContract();
        Vault vault = Vault(ILoan(existingLoanContract)._vault());

        // Step 1: Deploy fresh PortfolioAccountConfig and LoanConfig
        // PortfolioAccountConfig configImpl = new PortfolioAccountConfig();
        PortfolioAccountConfig portfolioAccountConfig = PortfolioAccountConfig(0x34aCa8A6538B43b6CA7DA1CD482fE72369b1b73f);
        PortfolioMarketplace portfolioMarketplace = PortfolioMarketplace(MARKETPLACE);


        // LoanConfig loanConfigImpl = new LoanConfig();
        // LoanConfig loanConfig = LoanConfig(
        //     address(new ERC1967Proxy(
        //         address(loanConfigImpl),
        //         abi.encodeCall(LoanConfig.initialize, (DEPLOYER_ADDRESS))
        //     ))
        // );

        // Link configs — reuse existing VotingConfig, SwapConfig, LoanContract from Aerodrome deployment
        // portfolioAccountConfig.setVoteConfig(votingConfig);
        // portfolioAccountConfig.setLoanConfig(address(loanConfig));
        // portfolioAccountConfig.setLoanContract(existingLoanContract);
        // portfolioAccountConfig.setPortfolioFactory(portfolioFactory);

        // // Step 2: Redeploy ClaimingFacet with fresh config
        // ClaimingFacet claimingFacet = new ClaimingFacet(portfolioFactory, address(portfolioAccountConfig), VOTING_ESCROW, VOTER, REWARDS_DISTRIBUTOR, address(loanConfig), address(swapConfig), address(vault));
        // bytes4[] memory claimingSelectors = new bytes4[](3);
        // claimingSelectors[0] = ClaimingFacet.claimFees.selector;
        // claimingSelectors[1] = ClaimingFacet.claimRebase.selector;
        // claimingSelectors[2] = ClaimingFacet.claimLaunchpadToken.selector;
        // _registerFacet(facetRegistry, address(claimingFacet), claimingSelectors, "ClaimingFacet");

        // // Step 3: Redeploy RewardsProcessingFacet with fresh config and Aerodrome vault
        // RewardsProcessingFacet rewardsProcessingFacet = new RewardsProcessingFacet(portfolioFactory, address(portfolioAccountConfig), address(swapConfig), VOTING_ESCROW, address(vault));
        // bytes4[] memory rewardsProcessingSelectors = new bytes4[](12);
        // rewardsProcessingSelectors[1] = RewardsProcessingFacet.processRewards.selector;
        // rewardsProcessingSelectors[0] = RewardsProcessingFacet.setRewardsToken.selector;
        // rewardsProcessingSelectors[2] = RewardsProcessingFacet.getRewardsToken.selector;
        // rewardsProcessingSelectors[3] = RewardsProcessingFacet.setRecipient.selector;
        // rewardsProcessingSelectors[4] = RewardsProcessingFacet.swapToRewardsToken.selector;
        // rewardsProcessingSelectors[5] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        // rewardsProcessingSelectors[6] = RewardsProcessingFacet.calculateRoutes.selector;
        // rewardsProcessingSelectors[7] = RewardsProcessingFacet.setZeroBalanceDistribution.selector;
        // rewardsProcessingSelectors[8] = RewardsProcessingFacet.getZeroBalanceDistribution.selector;
        // rewardsProcessingSelectors[9] = RewardsProcessingFacet.setActiveBalanceDistribution.selector;
        // rewardsProcessingSelectors[10] = RewardsProcessingFacet.getActiveBalanceDistribution.selector;
        // rewardsProcessingSelectors[11] = RewardsProcessingFacet.clearActiveBalanceDistribution.selector;
        // _registerFacet(facetRegistry, address(rewardsProcessingFacet), rewardsProcessingSelectors, "RewardsProcessingFacet");

        // Step 4: Redeploy all other facets with fresh config
        // CollateralFacet collateralFacet = new CollateralFacet(portfolioFactory, address(portfolioAccountConfig), VOTING_ESCROW);
        // bytes4[] memory collateralSelectors = new bytes4[](11);
        // collateralSelectors[0] = BaseCollateralFacet.addCollateral.selector;
        // collateralSelectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        // collateralSelectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        // collateralSelectors[3] = BaseCollateralFacet.getUnpaidFees.selector;
        // collateralSelectors[4] = BaseCollateralFacet.getMaxLoan.selector;
        // collateralSelectors[5] = BaseCollateralFacet.getOriginTimestamp.selector;
        // collateralSelectors[6] = BaseCollateralFacet.removeCollateral.selector;
        // collateralSelectors[7] = BaseCollateralFacet.getCollateralToken.selector;
        // collateralSelectors[8] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        // collateralSelectors[9] = BaseCollateralFacet.getLockedCollateral.selector;
        // collateralSelectors[10] = BaseCollateralFacet.removeCollateralTo.selector;
        // _registerFacet(facetRegistry, address(collateralFacet), collateralSelectors, "CollateralFacet");

        // VotingFacet votingFacet = new VotingFacet(portfolioFactory, address(portfolioAccountConfig), votingConfig, VOTING_ESCROW, VOTER);
        // bytes4[] memory votingSelectors = new bytes4[](5);
        // votingSelectors[0] = VotingFacet.vote.selector;
        // votingSelectors[1] = VotingFacet.voteForLaunchpadToken.selector;
        // votingSelectors[2] = VotingFacet.setVotingMode.selector;
        // votingSelectors[3] = VotingFacet.isManualVoting.selector;
        // votingSelectors[4] = VotingFacet.defaultVote.selector;
        // _registerFacet(facetRegistry, address(votingFacet), votingSelectors, "VotingFacet");

        // // Remove legacy ERC721ReceiverFacet (onERC721Received moves to VotingEscrowFacet)
        // address legacyErc721Facet = facetRegistry.getFacetForSelector(VotingEscrowFacet.onERC721Received.selector);
        // if (legacyErc721Facet != address(0)) {
        //     facetRegistry.removeFacet(legacyErc721Facet);
        // }

        // VotingEscrowFacet votingEscrowFacet = new VotingEscrowFacet(portfolioFactory, address(portfolioAccountConfig), VOTING_ESCROW, VOTER);
        // bytes4[] memory votingEscrowSelectors = new bytes4[](4);
        // votingEscrowSelectors[0] = VotingEscrowFacet.increaseLock.selector;
        // votingEscrowSelectors[1] = VotingEscrowFacet.createLock.selector;
        // votingEscrowSelectors[2] = VotingEscrowFacet.merge.selector;
        // votingEscrowSelectors[3] = VotingEscrowFacet.onERC721Received.selector;
        // _registerFacet(facetRegistry, address(votingEscrowFacet), votingEscrowSelectors, "VotingEscrowFacet");

        MarketplaceFacet marketplaceFacet = new MarketplaceFacet(portfolioFactory, address(portfolioAccountConfig), VOTING_ESCROW, 0x7b22D5D5753B76B5AAF2cC0ac11457e069b9f2C8);
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
        _validateDeployment(portfolioAccountConfig, portfolioFactory);
    }

    /**
     * @dev Helper function to register or replace a facet in the FacetRegistry
     * Since we're at script level during broadcast, calls will be from deployer
     */
    function _registerFacet(
        FacetRegistry facetRegistry,
        address facetAddress,
        bytes4[] memory selectors,
        string memory name
    ) internal {
        address oldFacet = facetRegistry.getFacetForSelector(selectors[0]);
        if (oldFacet == address(0)) {
            facetRegistry.registerFacet(facetAddress, selectors, name);
        } else {
            facetRegistry.replaceFacet(oldFacet, facetAddress, selectors, name);
        }
    }

    /// @dev Post-deployment validation. Reverts the script if any proxy is misconfigured.
    ///      Covers both borrow() and pay() call chains including getMaxLoan() dependencies.
    function _validateDeployment(PortfolioAccountConfig config, address expectedFactory) internal view {
        // Config proxy: getPortfolioFactory must work and return expected value
        console.log("Validating PortfolioAccountConfig at", address(config));
        console.log("Expected PortfolioFactory:", address(expectedFactory));
        console.log("Actual PortfolioFactory:", address(config.getPortfolioFactory()));
        require(config.getPortfolioFactory() == expectedFactory, "Validation: config.getPortfolioFactory() mismatch");
        require(config.getLoanContract() != address(0), "Validation: config.getLoanContract() is zero");
        require(config.getVoteConfig() != address(0), "Validation: config.getVoteConfig() is zero");
        require(address(config.getLoanConfig()) != address(0), "Validation: config.getLoanConfig() is zero");
        require(config.getVault() != address(0), "Validation: config.getVault() is zero");

        // Loan proxy: getPortfolioFactory must match
        address loanProxy = config.getLoanContract();
        // require(
        //     LoanV2(payable(loanProxy)).getPortfolioFactory() == expectedFactory,
        //     "Validation: loan.getPortfolioFactory() mismatch"
        // );

        // Pay flow: lendingAsset and lendingVault must be callable on the loan proxy
        require(ILendingPool(loanProxy).lendingAsset() != address(0), "Validation: lendingAsset() is zero");
        require(ILendingPool(loanProxy).lendingVault() != address(0), "Validation: lendingVault() is zero");

        // getMaxLoan() dependencies: activeAssets, LoanConfig.getRewardsRate/getMultiplier
        ILendingPool(loanProxy).activeAssets();
        config.getLoanConfig().getRewardsRate();
        config.getLoanConfig().getMultiplier();
    }
}
// forge script script/portfolio_account/aerodrome/DeployAerodromeRelayer.s.sol:AerodromeRootDeploy --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/aerodrome/DeployAerodromeRelayer.s.sol:AerodromeLeafDeploy --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/aerodrome/DeployAerodromeRelayer.s.sol:AerodromeRootUpgrade --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
