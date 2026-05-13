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
