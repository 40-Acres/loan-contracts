// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ResetDebtCounterFacet} from "../../../src/facets/account/collateral/ResetDebtCounterFacet.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";

/**
 * @title DeployResetFacet
 * @dev Deploys the one-shot ResetDebtCounterFacet and outputs everything the multisig
 *      needs to register it, call it on affected portfolios, and remove it.
 *
 * Usage:
 *   forge script script/portfolio_account/helper/DeployResetFacet.s.sol:DeployResetFacet \
 *     --rpc-url $RPC_URL --broadcast
 *
 * After deployment, the multisig (FacetRegistry owner) must execute 4 transactions:
 *   TX1: FacetRegistry.registerFacet(facetAddr, [selector], "ResetDebtCounterFacet")
 *   TX2: Portfolio1.resetDebtCounters()
 *   TX3: Portfolio2.resetDebtCounters()
 *   TX4: FacetRegistry.removeFacet(facetAddr)
 */
contract DeployResetFacet is Script {

    // Affected portfolios (aerodrome-usdc factory)
    address constant PORTFOLIO_1 = 0x2A2273ce2Caf9Be6541327cE17F1559be440237c; // owner: 0xCB7D...
    address constant PORTFOLIO_2 = 0xc5244B1a255b4dcd1b4ECdA082F7CfadaC759C5b; // owner: 0x84f2...

    // FacetRegistry for aerodrome-usdc factory
    address constant FACET_REGISTRY = 0xC2b32A782B7D98939c9403343B9e6D3c019004a2;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        ResetDebtCounterFacet facet = new ResetDebtCounterFacet();
        vm.stopBroadcast();

        bytes4 selector = ResetDebtCounterFacet.resetDebtCounters.selector;

        console.log("");
        console.log("========================================");
        console.log("  ResetDebtCounterFacet Deployed");
        console.log("========================================");
        console.log("");
        console.log("Facet address:", address(facet));
        console.log("Selector:     ", vm.toString(abi.encodePacked(selector)));
        console.log("Function:      resetDebtCounters()");
        console.log("");
        console.log("FacetRegistry:", FACET_REGISTRY);
        console.log("");
        console.log("--- Affected Portfolios ---");
        console.log("Portfolio 1:", PORTFOLIO_1);
        console.log("  Owner: 0xCB7D87F5502fC91529E0fE92373dDDd8Ff1f3D7c");
        console.log("  undercollateralizedDebt: ~2,996 USDC");
        console.log("");
        console.log("Portfolio 2:", PORTFOLIO_2);
        console.log("  Owner: 0x84f2213CCBc3eCa68bbF01365549E9f42A5515fB");
        console.log("  undercollateralizedDebt: ~444 USDC");
        console.log("");
        console.log("--- Multisig Transactions (4 total) ---");
        console.log("");
        console.log("TX1: Register facet");
        console.log("  To:   ", FACET_REGISTRY);
        console.log("  Call:  registerFacet(address,bytes4[],string)");
        console.log("  Args:  facet=<deployed address>, selectors=[", vm.toString(abi.encodePacked(selector)), "], name='ResetDebtCounterFacet'");
        console.log("");
        console.log("TX2: Reset portfolio 1");
        console.log("  To:   ", PORTFOLIO_1);
        console.log("  Call:  resetDebtCounters()");
        console.log("  Data: ", vm.toString(abi.encodeWithSelector(selector)));
        console.log("");
        console.log("TX3: Reset portfolio 2");
        console.log("  To:   ", PORTFOLIO_2);
        console.log("  Call:  resetDebtCounters()");
        console.log("  Data: ", vm.toString(abi.encodeWithSelector(selector)));
        console.log("");
        console.log("TX4: Remove facet");
        console.log("  To:   ", FACET_REGISTRY);
        console.log("  Call:  removeFacet(address)");
        console.log("  Args:  facet=<deployed address>");
        console.log("");
        console.log("========================================");
    }
}

// forge script script/portfolio_account/helper/DeployResetFacet.s.sol:DeployResetFacet --chain-id 8453 --rpc-url $BASE_RPC_URL --broadcast --verify --via-ir
