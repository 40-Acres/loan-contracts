// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./facets/AccountFacetsDeploy.s.sol";
import {DeployBridgeFacet} from "./facets/DeployBridgeFacet.s.sol";
import {DeployClaimingFacet} from "./facets/DeployClaimingFacet.s.sol";
import {DeployCollateralFacet} from "./facets/DeployCollateralFacet.s.sol";
import {DeployLendingFacet} from "./facets/DeployLendingFacet.s.sol";
import {DeployVotingFacet} from "./facets/DeployVotingFacet.s.sol";
import {DeploySwapFacet} from "./facets/DeploySwapFacet.s.sol";
import {DeployMigrationFacet} from "./facets/DeployMigrationFacet.s.sol";

contract DeployFacets is AccountFacetsDeploy {
    DeployBridgeFacet deployBridgeFacet = new DeployBridgeFacet();
    DeployClaimingFacet deployClaimingFacet = new DeployClaimingFacet();
    DeployCollateralFacet deployCollateralFacet = new DeployCollateralFacet();
    DeployLendingFacet deployLendingFacet = new DeployLendingFacet();
    DeployVotingFacet deployVotingFacet = new DeployVotingFacet();
    DeploySwapFacet deploySwapFacet = new DeploySwapFacet();
    DeployMigrationFacet deployMigrationFacet = new DeployMigrationFacet();

    function deploy(address portfolioFactory, address portfolioAccountConfig, address votingConfig, address votingEscrow, address voter, address rewardsDistributor, address loanConfig, address usdc, address swapConfig, address loanContract) external {
        deployBridgeFacet.deploy(portfolioFactory, portfolioAccountConfig, usdc);
        deployClaimingFacet.deploy(portfolioFactory, portfolioAccountConfig, votingEscrow, voter, rewardsDistributor, loanConfig, swapConfig);
        deployCollateralFacet.deploy(portfolioFactory, portfolioAccountConfig, votingEscrow);
        deployLendingFacet.deploy(portfolioFactory, portfolioAccountConfig);
        deployVotingFacet.deploy(portfolioFactory, portfolioAccountConfig, votingConfig, votingEscrow, voter);
        deploySwapFacet.deploy(portfolioFactory, portfolioAccountConfig, swapConfig);
        deployMigrationFacet.deploy(portfolioFactory, portfolioAccountConfig, votingEscrow, loanContract);
    }
}

// Usage examples:
// forge script script/portfolio_account/DeployAllFacets.s.sol:DeployAllFacets --rpc-url $RPC_URL --broadcast
// forge script script/portfolio_account/DeployAllFacets.s.sol:DeployAerodromeFacet --rpc-url $RPC_URL --broadcast
// forge script script/portfolio_account/DeployAllFacets.s.sol:UpgradeAerodromeFacet --rpc-url $RPC_URL --broadcast

