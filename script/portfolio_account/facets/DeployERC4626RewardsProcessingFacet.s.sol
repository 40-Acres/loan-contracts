// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {ERC4626RewardsProcessingFacet} from "../../../src/facets/account/erc4626/ERC4626RewardsProcessingFacet.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";

/**
 * @title DeployERC4626RewardsProcessingFacet
 * @dev Deploy the rewards-processing facet for ERC4626 vault-share collateral.
 *      COLLATERAL_VAULT must match the vault used by the ERC4626LendingFacet so
 *      the debt and utilization reads stay consistent with borrow time.
 */
contract DeployERC4626RewardsProcessingFacet is AccountFacetsDeploy {

    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address SWAP_CONFIG = vm.envAddress("SWAP_CONFIG");
        address COLLATERAL_VAULT = vm.envAddress("COLLATERAL_VAULT");
        address LENDING_VAULT = vm.envAddress("LENDING_VAULT");
        address DEFAULT_TOKEN = vm.envAddress("DEFAULT_TOKEN");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        ERC4626RewardsProcessingFacet facet = new ERC4626RewardsProcessingFacet(
            PORTFOLIO_FACTORY, SWAP_CONFIG, COLLATERAL_VAULT, LENDING_VAULT, DEFAULT_TOKEN
        );
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "RewardsProcessingFacet", false);

        RewardsConfigFacet configFacet = new RewardsConfigFacet(PORTFOLIO_FACTORY, SWAP_CONFIG);
        registerFacet(PORTFOLIO_FACTORY, address(configFacet), getSelectorsForConfigFacet(), "RewardsConfigFacet", false);

        vm.stopBroadcast();
    }

    function deploy(
        address portfolioFactory,
        address swapConfig,
        address collateralVault,
        address lendingVault,
        address defaultToken
    ) external returns (ERC4626RewardsProcessingFacet) {
        ERC4626RewardsProcessingFacet facet = new ERC4626RewardsProcessingFacet(
            portfolioFactory, swapConfig, collateralVault, lendingVault, defaultToken
        );
        registerFacet(portfolioFactory, address(facet), getSelectorsForFacet(), "RewardsProcessingFacet", true);

        RewardsConfigFacet configFacet = new RewardsConfigFacet(portfolioFactory, swapConfig);
        registerFacet(portfolioFactory, address(configFacet), getSelectorsForConfigFacet(), "RewardsConfigFacet", true);

        return facet;
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

    function getSelectorsForConfigFacet() internal pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = RewardsConfigFacet.setRecipient.selector;
        selectors[1] = RewardsConfigFacet.setZeroBalanceDistribution.selector;
        selectors[2] = RewardsConfigFacet.getZeroBalanceDistribution.selector;
        selectors[3] = RewardsConfigFacet.setActiveBalanceDistribution.selector;
        selectors[4] = RewardsConfigFacet.getActiveBalanceDistribution.selector;
        selectors[5] = RewardsConfigFacet.clearActiveBalanceDistribution.selector;
        return selectors;
    }
}
