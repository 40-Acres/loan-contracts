// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {BlackholeClaimingFacet} from "../../../src/facets/account/blackhole/BlackholeClaimingFacet.sol";
import {ClaimingFacet} from "../../../src/facets/account/claim/ClaimingFacet.sol";
import {BlackholeCollateralFacet} from "../../../src/facets/account/blackhole/BlackholeCollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {BlackholeVotingEscrowFacet} from "../../../src/facets/account/blackhole/BlackholeVotingEscrowFacet.sol";
import {BlackholeRewardsProcessingFacet} from "../../../src/facets/account/blackhole/BlackholeRewardsProcessingFacet.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {BlackholeMarketplaceFacet} from "../../../src/facets/account/blackhole/BlackholeMarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";

contract DeployBlackholeClaimingFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");
        address VOTER = vm.envAddress("VOTER");
        address GAUGE_MANAGER = vm.envAddress("GAUGE_MANAGER");
        address REWARDS_DISTRIBUTOR = vm.envAddress("REWARDS_DISTRIBUTOR");
        address SECONDARY_REWARDS_DISTRIBUTOR = vm.envOr("SECONDARY_REWARDS_DISTRIBUTOR", address(0));
        address LOAN_CONFIG = vm.envAddress("LOAN_CONFIG");
        address SWAP_CONFIG = vm.envAddress("SWAP_CONFIG");
        address VAULT = vm.envAddress("VAULT");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        BlackholeClaimingFacet facet = new BlackholeClaimingFacet(
            PORTFOLIO_FACTORY,
            VOTING_ESCROW,
            VOTER,
            GAUGE_MANAGER,
            REWARDS_DISTRIBUTOR,
            SECONDARY_REWARDS_DISTRIBUTOR,
            LOAN_CONFIG,
            SWAP_CONFIG,
            VAULT
        );
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "ClaimingFacet", false);
        vm.stopBroadcast();
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = ClaimingFacet.claimFees.selector;
        selectors[1] = ClaimingFacet.claimRebase.selector;
        selectors[2] = ClaimingFacet.claimLaunchpadToken.selector;
        return selectors;
    }
}

contract DeployBlackholeCollateralFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");
        address VOTER = vm.envAddress("VOTER");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        BlackholeCollateralFacet facet = new BlackholeCollateralFacet(PORTFOLIO_FACTORY, VOTING_ESCROW, VOTER);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "CollateralFacet", false);
        vm.stopBroadcast();
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = BaseCollateralFacet.addCollateral.selector;
        selectors[1] = BaseCollateralFacet.getTotalLockedCollateral.selector;
        selectors[2] = BaseCollateralFacet.getTotalDebt.selector;
        selectors[3] = BaseCollateralFacet.getMaxLoan.selector;
        selectors[4] = BaseCollateralFacet.getOriginTimestamp.selector;
        selectors[5] = BaseCollateralFacet.removeCollateral.selector;
        selectors[6] = BaseCollateralFacet.getCollateralToken.selector;
        selectors[7] = BaseCollateralFacet.enforceCollateralRequirements.selector;
        selectors[8] = BaseCollateralFacet.getLockedCollateral.selector;
        selectors[9] = BaseCollateralFacet.removeCollateralTo.selector;
        selectors[10] = BaseCollateralFacet.getLoanUtilization.selector;
        return selectors;
    }
}

contract DeployBlackholeVotingEscrowFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");
        address VOTER = vm.envAddress("VOTER");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        BlackholeVotingEscrowFacet facet = new BlackholeVotingEscrowFacet(PORTFOLIO_FACTORY, VOTING_ESCROW, VOTER);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "VotingEscrowFacet", false);
        vm.stopBroadcast();
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = BlackholeVotingEscrowFacet.increaseLock.selector;
        selectors[1] = BlackholeVotingEscrowFacet.createLock.selector;
        selectors[2] = BlackholeVotingEscrowFacet.merge.selector;
        selectors[3] = BlackholeVotingEscrowFacet.onERC721Received.selector;
        selectors[4] = BlackholeVotingEscrowFacet.mergeInternal.selector;
        return selectors;
    }
}

contract DeployBlackholeRewardsProcessingFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address SWAP_CONFIG = vm.envAddress("SWAP_CONFIG");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");
        address VAULT = vm.envAddress("VAULT");
        address REWARDS_TOKEN = vm.envAddress("REWARDS_TOKEN");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        BlackholeRewardsProcessingFacet facet = new BlackholeRewardsProcessingFacet(
            PORTFOLIO_FACTORY,
            SWAP_CONFIG,
            VOTING_ESCROW,
            VAULT,
            REWARDS_TOKEN
        );
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "RewardsProcessingFacet", false);
        vm.stopBroadcast();
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = RewardsProcessingFacet.processRewards.selector;
        selectors[1] = RewardsProcessingFacet.getRewardsToken.selector;
        selectors[2] = RewardsProcessingFacet.swapToRewardsToken.selector;
        selectors[3] = RewardsProcessingFacet.swapToRewardsTokenMultiple.selector;
        selectors[4] = RewardsProcessingFacet.calculateRoutes.selector;
        return selectors;
    }
}

contract DeployBlackholeMarketplaceFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");
        address MARKETPLACE = vm.envAddress("MARKETPLACE");
        address VOTER = vm.envAddress("VOTER");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        BlackholeMarketplaceFacet facet = new BlackholeMarketplaceFacet(PORTFOLIO_FACTORY, VOTING_ESCROW, MARKETPLACE, VOTER);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "MarketplaceFacet", false);
        vm.stopBroadcast();
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        selectors[1] = BaseMarketplaceFacet.makeListing.selector;
        selectors[2] = BaseMarketplaceFacet.cancelListing.selector;
        selectors[3] = BaseMarketplaceFacet.marketplace.selector;
        selectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        selectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        selectors[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
        selectors[7] = BaseMarketplaceFacet.isListingPurchasable.selector;
        return selectors;
    }
}
