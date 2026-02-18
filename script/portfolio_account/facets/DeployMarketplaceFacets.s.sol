// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {AccountFacetsDeploy} from "./AccountFacetsDeploy.s.sol";
import {VexyFacet} from "../../../src/facets/account/marketplace/VexyFacet.sol";
import {OpenXFacet} from "../../../src/facets/account/marketplace/OpenXFacet.sol";
import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../src/facets/marketplace/PortfolioMarketplace.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";

contract DeployVexyFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        VexyFacet facet = new VexyFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, VOTING_ESCROW);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "VexyFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig, address votingEscrow) external {
        VexyFacet newFacet = new VexyFacet(portfolioFactory, portfolioAccountConfig, votingEscrow);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "VexyFacet", true);
        
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = VexyFacet.buyVexyListing.selector;
        return selectors;
    }
}

contract DeployOpenXFacet is AccountFacetsDeploy {
    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        OpenXFacet facet = new OpenXFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, VOTING_ESCROW);
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "OpenXFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig, address votingEscrow) external {
        OpenXFacet newFacet = new OpenXFacet(portfolioFactory, portfolioAccountConfig, votingEscrow);
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "OpenXFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = OpenXFacet.buyOpenXListing.selector;
        return selectors;
    }
}

contract DeployMarketplaceFacet is AccountFacetsDeploy {
    address public constant DEPLOYER_ADDRESS = 0x40FecA5f7156030b78200450852792ea93f7c6cd;

    function run() external {
        address PORTFOLIO_FACTORY = vm.envAddress("PORTFOLIO_FACTORY");
        address PORTFOLIO_ACCOUNT_CONFIG = vm.envAddress("PORTFOLIO_ACCOUNT_CONFIG");
        address VOTING_ESCROW = vm.envAddress("VOTING_ESCROW");
        address portfolioMgr = address(PortfolioFactory(PORTFOLIO_FACTORY).portfolioManager());
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        PortfolioMarketplace portfolioMarketplace = new PortfolioMarketplace(portfolioMgr, VOTING_ESCROW, 100, DEPLOYER_ADDRESS);
        MarketplaceFacet facet = new MarketplaceFacet(PORTFOLIO_FACTORY, PORTFOLIO_ACCOUNT_CONFIG, VOTING_ESCROW, address(portfolioMarketplace));
        registerFacet(PORTFOLIO_FACTORY, address(facet), getSelectorsForFacet(), "MarketplaceFacet", false);
        vm.stopBroadcast();
    }

    function deploy(address portfolioFactory, address portfolioAccountConfig, address votingEscrow) external {
        address portfolioMgr = address(PortfolioFactory(portfolioFactory).portfolioManager());
        PortfolioMarketplace portfolioMarketplace = new PortfolioMarketplace(portfolioMgr, votingEscrow, 100, DEPLOYER_ADDRESS);
        MarketplaceFacet newFacet = new MarketplaceFacet(portfolioFactory, portfolioAccountConfig, votingEscrow, address(portfolioMarketplace));
        registerFacet(portfolioFactory, address(newFacet), getSelectorsForFacet(), "MarketplaceFacet", true);
    }

    function getSelectorsForFacet() internal pure override returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = BaseMarketplaceFacet.processPayment.selector;
        selectors[1] = BaseMarketplaceFacet.finalizePurchase.selector;
        selectors[2] = BaseMarketplaceFacet.buyMarketplaceListing.selector;
        selectors[3] = BaseMarketplaceFacet.getListing.selector;
        selectors[4] = BaseMarketplaceFacet.transferDebtToBuyer.selector;
        selectors[5] = BaseMarketplaceFacet.makeListing.selector;
        selectors[6] = BaseMarketplaceFacet.cancelListing.selector;
        selectors[7] = BaseMarketplaceFacet.marketplace.selector;
        selectors[8] = BaseMarketplaceFacet.getListingNonce.selector;
        selectors[9] = BaseMarketplaceFacet.isListingValid.selector;
        return selectors;
    }
}