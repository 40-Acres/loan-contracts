// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {FacetRegistry} from "../../src/accounts/FacetRegistry.sol";
import {BridgeFacet} from "../../src/facets/account/bridge/BridgeFacet.sol";
import {ClaimingFacet} from "../../src/facets/account/claim/ClaimingFacet.sol";
import {LendingFacet} from "../../src/facets/account/lending/LendingFacet.sol";
import {MigrationFacet} from "../../src/facets/account/migration/MigrationFacet.sol";
import {VotingFacet} from "../../src/facets/account/vote/VotingFacet.sol";
import {SuperchainVotingFacet} from "../../src/facets/account/vote/SuperchainVoting.sol";
import {VotingEscrowFacet} from "../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {PortfolioFactory} from "../../src/accounts/PortfolioFactory.sol";
import {CollateralFacet} from "../../src/facets/account/collateral/CollateralFacet.sol";

interface IOwnable {
    function owner() external view returns (address);
}

/**
 * @title AccountFacetsDeploy
 * @dev Base contract for deploying and upgrading account facets
 */
contract AccountFacetsDeploy is Script {
    /**
     * @dev Get the FacetRegistry address from environment variable or PortfolioFactory
     * @return The FacetRegistry instance
     */
    function getFacetRegistry() internal view returns (FacetRegistry) {
        address facetRegistryAddr = vm.envOr("FACET_REGISTRY", address(0));
        if (facetRegistryAddr != address(0)) {
            return FacetRegistry(facetRegistryAddr);
        }
        // Fallback: get from PortfolioFactory
        address portfolioFactoryAddr = vm.envOr("PORTFOLIO_FACTORY", address(0));
        require(portfolioFactoryAddr != address(0), "FACET_REGISTRY or PORTFOLIO_FACTORY must be set");
        PortfolioFactory portfolioFactory = PortfolioFactory(portfolioFactoryAddr);
        return portfolioFactory.facetRegistry();
    }
    /**
     * @dev Register a facet in the FacetRegistry
     * @param portfolioFactory The PortfolioFactory address
     * @param facetAddress The address of the facet
     * @param selectors The function selectors
     * @param name The name of the facet
     */
    function registerFacet(
        address portfolioFactory,
        address facetAddress,
        bytes4[] memory selectors,
        string memory name,
        bool impersonate
    ) internal {
        PortfolioFactory factory = PortfolioFactory(portfolioFactory);
        FacetRegistry registry = factory.facetRegistry();
        
        // Get the owner of the FacetRegistry
        address owner = IOwnable(address(registry)).owner();
        
        // Check if facet already exists
        address oldFacet = registry.getFacetForSelector(selectors[0]);
        
        // Impersonate the owner to register/replace the facet
        if (impersonate) {
            vm.startPrank(owner);
        }
        if (oldFacet == address(0)) {
            registry.registerFacet(facetAddress, selectors, name);
        } else {
            registry.replaceFacet(oldFacet, facetAddress, selectors, name);
        }
        if (impersonate) {
            vm.stopPrank();
        }
    }


    /**
     * @dev Get selectors for a facet (must be implemented by child contracts or passed as parameter)
     * This is a placeholder - selectors should be provided when calling register/upgrade functions
     */
    function getSelectorsForFacet() internal virtual pure returns (bytes4[] memory) {
        // This should be overridden or selectors should be passed directly
        revert("Selectors must be provided explicitly");
    }
}

contract DeployFacets is AccountFacetsDeploy {
    DeployBridgeFacet deployBridgeFacet = new DeployBridgeFacet();
    DeployClaimingFacet deployClaimingFacet = new DeployClaimingFacet();
    DeployCollateralFacet deployCollateralFacet = new DeployCollateralFacet();
    DeployLendingFacet deployLendingFacet = new DeployLendingFacet();

    function deploy(address portfolioFactory, address portfolioAccountConfig, address votingEscrow, address voter, address rewardsDistributor, address loanConfig, address usdc) external {
        deployBridgeFacet.deploy(portfolioFactory, portfolioAccountConfig, usdc);
        deployClaimingFacet.deploy(portfolioFactory, portfolioAccountConfig, votingEscrow, voter, rewardsDistributor, loanConfig);
        deployCollateralFacet.deploy(portfolioFactory, portfolioAccountConfig, votingEscrow);
        deployLendingFacet.deploy(portfolioFactory, portfolioAccountConfig, loanConfig);
    }
}

/**
 * @title DeployBridgeFacet
 * @dev Deploy BridgeFacet contract
 */
contract DeployBridgeFacet is AccountFacetsDeploy {

    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");
        address USDC = vm.envAddress("USDC");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        BridgeFacet newFacet = new BridgeFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, USDC);
        
        // get old facet from facet registry
        FacetRegistry registry = getFacetRegistry();
        registerFacet(PORTFOLIO_FACTORY, address(newFacet), getSelectorsForFacet(), "BridgeFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig, address usdc) external {
        BridgeFacet newFacet = new BridgeFacet(portfolioFactory, portfolioAccountConfig, usdc);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "BridgeFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = BridgeFacet.bridge.selector;
        return selectors;
    }
}

/**
 * @title DeployClaimingFacet
 * @dev Deploy ClaimingFacet contract
 */
contract DeployClaimingFacet is AccountFacetsDeploy {

    function run() external {     
        address PORTFOLIO_FACTORY  = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");
        address VOTER = vm.envAddress("VOTER");
        address REWARDS_DISTRIBUTOR = vm.envAddress("REWARDS_DISTRIBUTOR");
        address LOAN_CONFIG = vm.envAddress("LOAN_CONFIG");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        ClaimingFacet facet = new ClaimingFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, VOTING_ESCROW, VOTER, REWARDS_DISTRIBUTOR, LOAN_CONFIG);
        
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "ClaimingFacet", false);
        
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig, address votingEscrow, address voter, address rewardsDistributor, address loanConfig) external returns (ClaimingFacet) {
        
        ClaimingFacet facet = new ClaimingFacet(portfolioFactory, portfolioAccountConfig, votingEscrow, voter, rewardsDistributor, loanConfig);
        bytes4[] memory selectors = getSelectorsForFacet();
        registerFacet(portfolioFactory, address(facet), selectors, "ClaimingFacet", true);
        
        return ClaimingFacet(address(facet));
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = ClaimingFacet.claimFees.selector;
        selectors[1] = ClaimingFacet.claimRebase.selector;
        selectors[2] = ClaimingFacet.claimLaunchpadToken.selector;
        selectors[3] = ClaimingFacet.processRewards.selector;
        return selectors;
    }
}

contract DeployCollateralFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        CollateralFacet facet = new CollateralFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, VOTING_ESCROW);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "CollateralFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig, address votingEscrow) external {
        CollateralFacet newFacet = new CollateralFacet(portfolioFactory, portfolioAccountConfig, votingEscrow);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "CollateralFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = CollateralFacet.addCollateral.selector;
        selectors[1] = CollateralFacet.getTotalLockedCollateral.selector;
        selectors[2] = CollateralFacet.getTotalDebt.selector;
        selectors[3] = CollateralFacet.removeCollateral.selector;
        return selectors;
    }
}

contract DeployLendingFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");
        address LOAN_CONFIG = vm.envAddress("LOAN_CONFIG");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        LendingFacet facet = new LendingFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, LOAN_CONFIG);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "LendingFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig, address loanConfig) external {
        LendingFacet newFacet = new LendingFacet(portfolioFactory, portfolioAccountConfig, loanConfig);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "LendingFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = LendingFacet.borrow.selector;
        selectors[1] = LendingFacet.pay.selector;
        return selectors;
    }
}

function DeployVotingFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");
        address VOTER = vm.envAddress("VOTER");
    }
}

// Usage examples:
// forge script script/portfolio_account/DeployAllFacets.s.sol:DeployAllFacets --rpc-url $RPC_URL --broadcast
// forge script script/portfolio_account/DeployAllFacets.s.sol:DeployAerodromeFacet --rpc-url $RPC_URL --broadcast
// forge script script/portfolio_account/DeployAllFacets.s.sol:UpgradeAerodromeFacet --rpc-url $RPC_URL --broadcast

