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
import {BridgeFacet} from "../../../src/facets/account/bridge/BridgeFacet.sol";
import {SwapFacet} from "../../../src/facets/account/swap/SwapFacet.sol";
import {ClaimingFacet} from "../../../src/facets/account/claim/ClaimingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";
import {VotingEscrowFacet} from "../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {MigrationFacet} from "../../../src/facets/account/migration/MigrationFacet.sol";
import {VexyFacet} from "../../../src/facets/account/marketplace/VexyFacet.sol";
import {OpenXFacet} from "../../../src/facets/account/marketplace/OpenXFacet.sol";
import {ERC721ReceiverFacet} from "../../../src/facets/ERC721ReceiverFacet.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {DynamicFeesVault} from "../../../src/facets/account/vault/DynamicFeesVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IMigrationFacet} from "../../../src/facets/account/migration/IMigrationFacet.sol";
import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../src/facets/marketplace/PortfolioMarketplace.sol";

contract AerodromeDynamicFeesRootDeploy is Script {
    // Existing deployed addresses
    address public constant DEPLOYER_ADDRESS = 0x40FecA5f7156030b78200450852792ea93f7c6cd;
    address public constant EXISTING_PORTFOLIO_FACTORY = 0xfeEB5C58786617230095a008164b096e3205EAF2;
    address public constant SWAP_CONFIG = 0x3646C436f18f0e2E38E10D1A147f901a96BD4390;

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

        // Deploy new PortfolioAccountConfig for this factory
        PortfolioAccountConfig configImpl = new PortfolioAccountConfig();
        ERC1967Proxy configProxy = new ERC1967Proxy(address(configImpl), "");
        PortfolioAccountConfig portfolioAccountConfig = PortfolioAccountConfig(address(configProxy));
        portfolioAccountConfig.initialize(DEPLOYER_ADDRESS);

        // Deploy new VotingConfig
        VotingConfig votingConfigImpl = new VotingConfig();
        ERC1967Proxy votingConfigProxy = new ERC1967Proxy(address(votingConfigImpl), "");
        VotingConfig votingConfig = VotingConfig(address(votingConfigProxy));
        votingConfig.initialize(DEPLOYER_ADDRESS);

        // Deploy new LoanConfig
        LoanConfig loanConfigImpl = new LoanConfig();
        ERC1967Proxy loanConfigProxy = new ERC1967Proxy(address(loanConfigImpl), "");
        LoanConfig loanConfig = LoanConfig(address(loanConfigProxy));
        loanConfig.initialize(DEPLOYER_ADDRESS);

        // Set default loan config values
        loanConfig.setRewardsRate(2850);
        loanConfig.setMultiplier(52);

        // Set configs
        portfolioAccountConfig.setVoteConfig(address(votingConfig));
        portfolioAccountConfig.setLoanConfig(address(loanConfig));

        // Deploy DynamicFeesVault with proxy
        DynamicFeesVault vaultImplementation = new DynamicFeesVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        _vault = DynamicFeesVault(address(vaultProxy));

        // Initialize DynamicFeesVault
        _vault.initialize(USDC, "40base-USDC-DYNAMIC-VAULT", "40base-USDC-DV", address(portfolioFactory));

        // Set the vault as the loan contract in config (DynamicFeesVault implements ILendingPool)
        portfolioAccountConfig.setLoanContract(address(_vault));

        // Deploy all facets directly
        // This allows calls to be broadcast from deployer account

        // // Deploy BridgeFacet
        // BridgeFacet bridgeFacet = new BridgeFacet(address(portfolioFactory), address(portfolioAccountConfig), USDC, TOKEN_MESSENGER);
        // bytes4[] memory bridgeSelectors = new bytes4[](1);
        // bridgeSelectors[0] = BridgeFacet.bridge.selector;
        // _registerFacet(facetRegistry, address(bridgeFacet), bridgeSelectors, "BridgeFacet");

        // Deploy ClaimingFacet
        ClaimingFacet claimingFacet = new ClaimingFacet(address(portfolioFactory), address(portfolioAccountConfig), VOTING_ESCROW, VOTER, REWARDS_DISTRIBUTOR, address(loanConfig), address(swapConfig), address(_vault));
        bytes4[] memory claimingSelectors = new bytes4[](3);
        claimingSelectors[0] = ClaimingFacet.claimFees.selector;
        claimingSelectors[1] = ClaimingFacet.claimRebase.selector;
        claimingSelectors[2] = ClaimingFacet.claimLaunchpadToken.selector;
        _registerFacet(facetRegistry, address(claimingFacet), claimingSelectors, "ClaimingFacet");

        // Deploy CollateralFacet
        CollateralFacet collateralFacet = new CollateralFacet(address(portfolioFactory), address(portfolioAccountConfig), VOTING_ESCROW);
        bytes4[] memory collateralSelectors = new bytes4[](9);
        collateralSelectors[0] = CollateralFacet.addCollateral.selector;
        collateralSelectors[1] = CollateralFacet.getTotalLockedCollateral.selector;
        collateralSelectors[2] = CollateralFacet.getTotalDebt.selector;
        collateralSelectors[3] = CollateralFacet.getUnpaidFees.selector;
        collateralSelectors[4] = CollateralFacet.getMaxLoan.selector;
        collateralSelectors[5] = CollateralFacet.getOriginTimestamp.selector;
        collateralSelectors[6] = CollateralFacet.removeCollateral.selector;
        collateralSelectors[7] = CollateralFacet.getCollateralToken.selector;
        collateralSelectors[8] = CollateralFacet.enforceCollateralRequirements.selector;
        _registerFacet(facetRegistry, address(collateralFacet), collateralSelectors, "CollateralFacet");

        // Deploy LendingFacet
        LendingFacet lendingFacet = new LendingFacet(address(portfolioFactory), address(portfolioAccountConfig), USDC);
        bytes4[] memory lendingSelectors = new bytes4[](4);
        lendingSelectors[0] = LendingFacet.borrow.selector;
        lendingSelectors[1] = LendingFacet.pay.selector;
        lendingSelectors[2] = LendingFacet.setTopUp.selector;
        lendingSelectors[3] = LendingFacet.topUp.selector;
        _registerFacet(facetRegistry, address(lendingFacet), lendingSelectors, "LendingFacet");

        // Deploy VotingFacet
        VotingFacet votingFacet = new VotingFacet(address(portfolioFactory), address(portfolioAccountConfig), address(votingConfig), VOTING_ESCROW, VOTER);
        bytes4[] memory votingSelectors = new bytes4[](5);
        votingSelectors[0] = VotingFacet.vote.selector;
        votingSelectors[1] = VotingFacet.voteForLaunchpadToken.selector;
        votingSelectors[2] = VotingFacet.setVotingMode.selector;
        votingSelectors[3] = VotingFacet.isManualVoting.selector;
        votingSelectors[4] = VotingFacet.defaultVote.selector;
        _registerFacet(facetRegistry, address(votingFacet), votingSelectors, "VotingFacet");

        // Deploy VotingEscrowFacet
        VotingEscrowFacet votingEscrowFacet = new VotingEscrowFacet(address(portfolioFactory), address(portfolioAccountConfig), VOTING_ESCROW, VOTER);
        bytes4[] memory votingEscrowSelectors = new bytes4[](3);
        votingEscrowSelectors[0] = VotingEscrowFacet.increaseLock.selector;
        votingEscrowSelectors[1] = VotingEscrowFacet.createLock.selector;
        votingEscrowSelectors[2] = VotingEscrowFacet.merge.selector;
        _registerFacet(facetRegistry, address(votingEscrowFacet), votingEscrowSelectors, "VotingEscrowFacet");

        // Deploy SwapFacet
        SwapFacet swapFacet = new SwapFacet(address(portfolioFactory), address(portfolioAccountConfig), address(swapConfig));
        bytes4[] memory swapSelectors = new bytes4[](1);
        swapSelectors[0] = SwapFacet.userSwap.selector;
        _registerFacet(facetRegistry, address(swapFacet), swapSelectors, "SwapFacet");

        // Deploy MigrationFacet
        MigrationFacet migrationFacet = new MigrationFacet(address(portfolioFactory), address(portfolioAccountConfig), VOTING_ESCROW);
        bytes4[] memory migrationSelectors = new bytes4[](1);
        migrationSelectors[0] = IMigrationFacet.migrate.selector;
        _registerFacet(facetRegistry, address(migrationFacet), migrationSelectors, "MigrationFacet");

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
        PortfolioMarketplace portfolioMarketplace = new PortfolioMarketplace(address(portfolioFactory), address(VOTING_ESCROW), 100, DEPLOYER_ADDRESS);
        MarketplaceFacet marketplaceFacet = new MarketplaceFacet(address(portfolioFactory), address(portfolioAccountConfig), VOTING_ESCROW, address(portfolioMarketplace));
        bytes4[] memory marketplaceSelectors = new bytes4[](7);
        marketplaceSelectors[0] = MarketplaceFacet.processPayment.selector;
        marketplaceSelectors[1] = MarketplaceFacet.finalizePurchase.selector;
        marketplaceSelectors[2] = MarketplaceFacet.buyMarketplaceListing.selector;
        marketplaceSelectors[3] = MarketplaceFacet.getListing.selector;
        marketplaceSelectors[4] = MarketplaceFacet.transferDebtToBuyer.selector;
        marketplaceSelectors[5] = MarketplaceFacet.makeListing.selector;
        marketplaceSelectors[6] = MarketplaceFacet.cancelListing.selector;
        _registerFacet(facetRegistry, address(marketplaceFacet), marketplaceSelectors, "MarketplaceFacet");

        // Deploy ERC721ReceiverFacet
        ERC721ReceiverFacet erc721ReceiverFacet = new ERC721ReceiverFacet();
        bytes4[] memory erc721ReceiverSelectors = new bytes4[](1);
        erc721ReceiverSelectors[0] = ERC721ReceiverFacet.onERC721Received.selector;
        _registerFacet(facetRegistry, address(erc721ReceiverFacet), erc721ReceiverSelectors, "ERC721ReceiverFacet");

        // Deploy RewardsProcessingFacet
        RewardsProcessingFacet rewardsProcessingFacet = new RewardsProcessingFacet(address(portfolioFactory), address(portfolioAccountConfig), address(swapConfig), VOTING_ESCROW, address(_vault));
        bytes4[] memory rewardsProcessingSelectors = new bytes4[](10);
        rewardsProcessingSelectors[0] = RewardsProcessingFacet.processRewards.selector;
        rewardsProcessingSelectors[1] = RewardsProcessingFacet.setRewardsOption.selector;
        rewardsProcessingSelectors[2] = RewardsProcessingFacet.getRewardsOption.selector;
        rewardsProcessingSelectors[3] = RewardsProcessingFacet.getRewardsOptionPercentage.selector;
        rewardsProcessingSelectors[4] = RewardsProcessingFacet.setRewardsToken.selector;
        rewardsProcessingSelectors[5] = RewardsProcessingFacet.setRecipient.selector;
        rewardsProcessingSelectors[6] = RewardsProcessingFacet.setRewardsOptionPercentage.selector;
        rewardsProcessingSelectors[7] = RewardsProcessingFacet.getRewardsToken.selector;
        rewardsProcessingSelectors[8] = RewardsProcessingFacet.swapToRewardsToken.selector;
        rewardsProcessingSelectors[9] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        _registerFacet(facetRegistry, address(rewardsProcessingFacet), rewardsProcessingSelectors, "RewardsProcessingFacet");
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
}

// forge script script/portfolio_account/aerodrome/DeployAerodromeDynamicFees.s.sol:AerodromeDynamicFeesRootDeploy --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
