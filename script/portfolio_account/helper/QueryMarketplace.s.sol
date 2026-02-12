// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";

/**
 * @title QueryMarketplace
 * @dev Returns the marketplace contract address from a portfolio account
 *
 * Usage:
 *   forge script script/portfolio_account/helper/QueryMarketplace.s.sol:QueryMarketplace \
 *     --sig "run(address)" <PORTFOLIO> --rpc-url $RPC_URL
 *
 *   PORTFOLIO=0x... forge script script/portfolio_account/helper/QueryMarketplace.s.sol:QueryMarketplace \
 *     --sig "run()" --rpc-url $RPC_URL
 */
contract QueryMarketplace is Script {

    function run(address portfolio) external view {
        address marketplace = MarketplaceFacet(portfolio).marketplace();
        console.log("Marketplace:", marketplace);
    }

    function run() external view {
        address portfolio = vm.envAddress("PORTFOLIO");
        address marketplace = MarketplaceFacet(portfolio).marketplace();
        console.log("Marketplace:", marketplace);
    }
}
