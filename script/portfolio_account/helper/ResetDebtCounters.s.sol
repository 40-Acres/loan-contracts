// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {ResetDebtCounterFacet} from "../../../src/facets/account/collateral/ResetDebtCounterFacet.sol";

/**
 * @title ResetDebtCounters
 * @dev One-shot script: deploys a temporary facet, registers it, calls resetDebtCounters()
 *      on affected portfolios, then removes the facet. No lingering admin methods.
 *
 *      Must be run by the FacetRegistry owner (multisig).
 *
 * Usage:
 *   PORTFOLIOS="0x2A2273ce2Caf9Be6541327cE17F1559be440237c" \
 *   forge script script/portfolio_account/helper/ResetDebtCounters.s.sol:ResetDebtCounters \
 *     --rpc-url $RPC_URL --broadcast
 */
contract ResetDebtCounters is Script {
    address constant PORTFOLIO_MANAGER = 0x40Ac2e40ACb7bdD6EC83E468143262fe216529ec;

    function run() external {
        // Parse affected portfolio addresses from env
        string memory portfoliosStr = vm.envString("PORTFOLIOS");
        address[] memory portfolios = _parseAddresses(portfoliosStr);
        require(portfolios.length > 0, "No portfolios specified");

        // Discover factory + registry
        PortfolioManager pm = PortfolioManager(PORTFOLIO_MANAGER);
        bytes32 salt = keccak256(abi.encodePacked("aerodrome-usdc"));
        PortfolioFactory factory = PortfolioFactory(pm.factoryBySalt(salt));
        FacetRegistry registry = factory.facetRegistry();

        vm.startBroadcast();

        // 1. Deploy the one-shot facet
        ResetDebtCounterFacet resetFacet = new ResetDebtCounterFacet();
        console.log("Deployed ResetDebtCounterFacet at:", address(resetFacet));

        // 2. Register it with a single selector
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ResetDebtCounterFacet.resetDebtCounters.selector;
        registry.registerFacet(address(resetFacet), selectors, "ResetDebtCounterFacet");
        console.log("Registered facet in registry");

        // 3. Call resetDebtCounters() on each affected portfolio
        for (uint256 i = 0; i < portfolios.length; i++) {
            ResetDebtCounterFacet(portfolios[i]).resetDebtCounters();
            console.log("Reset counters for portfolio:", portfolios[i]);
        }

        // 4. Remove the facet — no lingering admin methods
        registry.removeFacet(address(resetFacet));
        console.log("Removed facet from registry");

        vm.stopBroadcast();
    }

    function _parseAddresses(string memory csv) internal pure returns (address[] memory) {
        // Count commas to determine array size
        uint256 count = 1;
        bytes memory b = bytes(csv);
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ",") count++;
        }

        address[] memory result = new address[](count);
        uint256 idx = 0;
        uint256 start = 0;

        for (uint256 i = 0; i <= b.length; i++) {
            if (i == b.length || b[i] == ",") {
                bytes memory addrBytes = new bytes(i - start);
                for (uint256 j = start; j < i; j++) {
                    addrBytes[j - start] = b[j];
                }
                result[idx] = _parseAddress(string(addrBytes));
                idx++;
                start = i + 1;
            }
        }
        return result;
    }

    function _parseAddress(string memory s) internal pure returns (address) {
        bytes memory b = bytes(s);
        uint256 result = 0;
        // Skip "0x" prefix
        uint256 startIdx = 0;
        if (b.length >= 2 && b[0] == "0" && (b[1] == "x" || b[1] == "X")) {
            startIdx = 2;
        }
        for (uint256 i = startIdx; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c >= 48 && c <= 57) {
                result = result * 16 + (c - 48);
            } else if (c >= 65 && c <= 70) {
                result = result * 16 + (c - 55);
            } else if (c >= 97 && c <= 102) {
                result = result * 16 + (c - 87);
            }
        }
        return address(uint160(result));
    }
}
