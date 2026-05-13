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


// forge script script/portfolio_account/velodrome/DeployVelodrome.s.sol:VelodromeRootDeploy --chain-id 10 --rpc-url $OP_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/velodrome/DeployVelodrome.s.sol:VelodromeLeafDeploy --chain-id 10 --rpc-url $OP_RPC_URL --broadcast --verify --via-ir

// forge script script/portfolio_account/velodrome/DeployVelodrome.s.sol:VelodromeLeafDeploy \
//     --chain-id 57073 \
//     --rpc-url $INK_RPC_URL \
//     --broadcast \
//     --verify \
//     --via-ir
