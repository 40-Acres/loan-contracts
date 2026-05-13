// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./facets/AccountFacetsDeploy.s.sol";
import {DeployBridgeFacet} from "./facets/DeployBridgeFacet.s.sol";
import {DeployClaimingFacet} from "./facets/DeployClaimingFacet.s.sol";
import {DeployCollateralFacet} from "./facets/DeployCollateralFacet.s.sol";
import {DeployLendingFacet} from "./facets/DeployLendingFacet.s.sol";
import {DeployVotingFacet} from "./facets/DeployVotingFacet.s.sol";
import {DeployVotingEscrowFacet} from "./facets/DeployVotingEscrowFacet.s.sol";

import {DeployMigrationFacet} from "./facets/DeployMigrationFacet.s.sol";
import {DeployMarketplaceFacet} from "./facets/DeployMarketplaceFacets.s.sol";
import {DeployRewardsProcessingFacet} from "./facets/DeployRewardsProcessingFacet.s.sol";

contract DeployFacets is AccountFacetsDeploy {
    DeployBridgeFacet deployBridgeFacet = new DeployBridgeFacet();
    DeployClaimingFacet deployClaimingFacet = new DeployClaimingFacet();
    DeployCollateralFacet deployCollateralFacet = new DeployCollateralFacet();
    DeployLendingFacet deployLendingFacet = new DeployLendingFacet();
    DeployVotingFacet deployVotingFacet = new DeployVotingFacet();
    DeployVotingEscrowFacet deployVotingEscrowFacet = new DeployVotingEscrowFacet();
DeployMigrationFacet deployMigrationFacet = new DeployMigrationFacet();
    DeployRewardsProcessingFacet deployRewardsProcessingFacet = new DeployRewardsProcessingFacet();
    DeployMarketplaceFacet deployMarketplaceFacet = new DeployMarketplaceFacet();

    function deploy(address portfolioFactory, address votingConfig, address votingEscrow, address voter, address rewardsDistributor, address loanConfig, address usdc, address tokenMessenger, uint32 destinationDomain, address swapConfig, address loanContract, address lendingToken, address vault) external {
        deployBridgeFacet.deploy(portfolioFactory, usdc, tokenMessenger, destinationDomain, swapConfig);
        deployClaimingFacet.deploy(portfolioFactory, votingEscrow, voter, rewardsDistributor, loanConfig, swapConfig, vault);
        deployCollateralFacet.deploy(portfolioFactory, votingEscrow);
        deployLendingFacet.deploy(portfolioFactory, lendingToken);
        deployVotingFacet.deploy(portfolioFactory, votingConfig, votingEscrow, voter);
        deployVotingEscrowFacet.deploy(portfolioFactory, votingEscrow, voter);
        deployMigrationFacet.deploy(portfolioFactory, votingEscrow);
        deployRewardsProcessingFacet.deploy(portfolioFactory, swapConfig, votingEscrow, vault);
        deployMarketplaceFacet.deploy(portfolioFactory, votingEscrow);
    }
}
