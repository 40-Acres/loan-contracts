// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfigDeploy} from "../DeployPortfolioFactoryConfig.s.sol";

import {DynamicYieldBasisLpFacet} from "../../../src/facets/account/yieldbasislp/DynamicYieldBasisLpFacet.sol";

/**
 * @title UpgradeDynamicYieldBasisLpFacet
 * @dev Redeploys ONLY DynamicYieldBasisLpFacet so it relinks the patched
 *      DynamicYieldBasisCollateralManager library (addCollateral drift-deadlock
 *      fix) and re-points its selectors in the FacetRegistry.
 *
 *      Why only this facet: addCollateral -- the deadlocking function -- is
 *      exposed solely by DynamicYieldBasisLpFacet (via deposit). The shared
 *      _snapshotIfNeeded change is behavior-neutral for gauge-set accounts
 *      (every live YB account has gauge set), so the Lending / Claiming /
 *      RewardsProcessing facets execute identical behavior on the old library
 *      and do not need redeployment. Targeted hotfix, minimal blast radius.
 *
 *      Caveat: if a gauge-less YB account ever exists, the un-upgraded facets
 *      would not perform the new direct-LP drift detection. Not a live scenario.
 *
 *      VAULT is the EXISTING live DynamicFeesVault -- the vault is unchanged by
 *      this fix; do NOT redeploy it.
 *
 *      The FacetRegistry owner is the multisig, so _registerFacet detects the
 *      deployer is not the owner and PRINTS replaceFacet(old,new,...) Safe
 *      calldata rather than executing. The multisig submits that call to
 *      complete the cut.
 *
 *      Run (ETH market, WETH loan vs yb-WETH):
 *        VAULT=0xB543dBe91be1D34B5cEe98E8A4366dA7B999e4A1 \
 *        YIELDBASIS_LP_GAUGE=0xe4e656B5215a82009969219b1bAbB7c0757A3315 \
 *        FACTORY_SALT=yieldbasiseth \
 *        forge script script/portfolio_account/yieldbasis/UpgradeDynamicYieldBasisLpFacets.s.sol:UpgradeDynamicYieldBasisLpFacet \
 *          --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
 *
 *      Dry-run first WITHOUT --broadcast to capture the printed Safe calldata.
 */
contract UpgradeDynamicYieldBasisLpFacet is PortfolioFactoryConfigDeploy {
    // YieldBasis gauge reward token (Ethereum mainnet).
    address public constant YB = 0x01791F726B4103694969820be083196cC7c045fF;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        address gauge = vm.envAddress("YIELDBASIS_LP_GAUGE");
        require(gauge != address(0), "Set YIELDBASIS_LP_GAUGE env variable");

        string memory factorySalt = vm.envString("FACTORY_SALT");
        require(bytes(factorySalt).length != 0, "Set FACTORY_SALT env variable");

        PortfolioManager portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);
        PortfolioFactory portfolioFactory =
            PortfolioFactory(portfolioManager.factoryBySalt(keccak256(abi.encodePacked(factorySalt))));
        require(address(portfolioFactory) != address(0), "PortfolioFactory not found for salt");

        address vault = vm.envAddress("VAULT");
        require(vault != address(0), "Set VAULT env variable");

        FacetRegistry facetRegistry = portfolioFactory.facetRegistry();

        // Lp facet: deposit/withdraw + ICollateralFacet surface. Carries the
        // addCollateral drift-deadlock fix.
        DynamicYieldBasisLpFacet lpFacet =
            new DynamicYieldBasisLpFacet(address(portfolioFactory), gauge, YB, vault);
        bytes4[] memory lpSelectors = new bytes4[](10);
        lpSelectors[0] = DynamicYieldBasisLpFacet.deposit.selector;
        lpSelectors[1] = DynamicYieldBasisLpFacet.withdraw.selector;
        lpSelectors[2] = DynamicYieldBasisLpFacet.setStakedMode.selector;
        lpSelectors[3] = DynamicYieldBasisLpFacet.getStakingState.selector;
        lpSelectors[4] = DynamicYieldBasisLpFacet.getTotalLockedCollateral.selector;
        lpSelectors[5] = DynamicYieldBasisLpFacet.getTotalDebt.selector;
        lpSelectors[6] = DynamicYieldBasisLpFacet.getMaxLoan.selector;
        lpSelectors[7] = DynamicYieldBasisLpFacet.enforceCollateralRequirements.selector;
        lpSelectors[8] = DynamicYieldBasisLpFacet.getLoanUtilization.selector;
        lpSelectors[9] = DynamicYieldBasisLpFacet.getCollateralToken.selector;
        _registerFacet(facetRegistry, address(lpFacet), lpSelectors, "DynamicYieldBasisLpFacet");

        vm.stopBroadcast();
    }
}

// ETH market (WETH loan vs yb-WETH):
// VAULT=0xB543dBe91be1D34B5cEe98E8A4366dA7B999e4A1 YIELDBASIS_LP_GAUGE=0xe4e656B5215a82009969219b1bAbB7c0757A3315 FACTORY_SALT=yieldbasiseth forge script script/portfolio_account/yieldbasis/UpgradeDynamicYieldBasisLpFacets.s.sol:UpgradeDynamicYieldBasisLpFacet --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
