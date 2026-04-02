// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {PortfolioFactoryConfigDeploy} from "../DeployPortfolioFactoryConfig.s.sol";
import {WalletFacet} from "../../../src/facets/account/wallet/WalletFacet.sol";
import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {FortyAcresMarketplaceFacet} from "../../../src/facets/account/marketplace/FortyAcresMarketplaceFacet.sol";
import {OpenXFacet} from "../../../src/facets/account/marketplace/OpenXFacet.sol";
import {VexyFacet} from "../../../src/facets/account/marketplace/VexyFacet.sol";
import {SwapMod} from "../../../src/facets/account/swap/SwapMod.sol";
import {console} from "forge-std/console.sol";

contract WalletDeploy is PortfolioFactoryConfigDeploy {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address public constant MARKETPLACE = 0x3938F063e3c8699EeB7D847915dF093Ea304a0F1;

    PortfolioManager public constant PORTFOLIO_MANAGER = PortfolioManager(0x5f3736D7686edb3F74c0726D8fDF3f58252cC1F9);

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deployWallet();
        vm.stopBroadcast();
    }

    function _deployWallet() internal {
        // Create a new factory for wallet accounts
        (PortfolioFactory portfolioFactory, FacetRegistry facetRegistry) = PORTFOLIO_MANAGER.deployFactory(bytes32(keccak256(abi.encodePacked("wallet"))));

        console.log("Deployed wallet factory at:", address(portfolioFactory));
        // Deploy configs
        (PortfolioFactoryConfig portfolioFactoryConfig, , , SwapConfig swapConfig) = PortfolioFactoryConfigDeploy._deploy(false, address(portfolioFactory));
        portfolioFactory.setPortfolioFactoryConfig(address(portfolioFactoryConfig));

        // Deploy and register all facets
        _deployFacets(facetRegistry, portfolioFactory, portfolioFactoryConfig, swapConfig);
    }

    function _deployFacets(
        FacetRegistry facetRegistry,
        PortfolioFactory portfolioFactory,
        PortfolioFactoryConfig portfolioFactoryConfig,
        SwapConfig swapConfig
    ) internal {
        // Deploy WalletFacet
        WalletFacet walletFacet = new WalletFacet(address(portfolioFactory), address(swapConfig));
        bytes4[] memory walletSelectors = new bytes4[](6);
        walletSelectors[0] = WalletFacet.transferERC20.selector;
        walletSelectors[1] = WalletFacet.transferNFT.selector;
        walletSelectors[2] = WalletFacet.receiveERC20.selector;
        walletSelectors[3] = WalletFacet.swap.selector;
        walletSelectors[4] = WalletFacet.onERC721Received.selector;
        walletSelectors[5] = WalletFacet.enforceCollateralRequirements.selector;
        // _registerFacet(facetRegistry, address(walletFacet), walletSelectors, "WalletFacet");

        // Deploy MarketplaceFacet (seller-side: makeListing, cancelListing, receiveSaleProceeds)
        MarketplaceFacet marketplaceFacet = new MarketplaceFacet(address(portfolioFactory), VOTING_ESCROW, MARKETPLACE);
        bytes4[] memory marketplaceSelectors = new bytes4[](8);
        marketplaceSelectors[0] = BaseMarketplaceFacet.makeListing.selector;
        marketplaceSelectors[1] = BaseMarketplaceFacet.cancelListing.selector;
        marketplaceSelectors[2] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        marketplaceSelectors[3] = BaseMarketplaceFacet.marketplace.selector;
        marketplaceSelectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        marketplaceSelectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        marketplaceSelectors[6] = BaseMarketplaceFacet.clearExpiredSaleAuthorization.selector;
        marketplaceSelectors[7] = BaseMarketplaceFacet.isListingPurchasable.selector;
        // _registerFacet(facetRegistry, address(marketplaceFacet), marketplaceSelectors, "MarketplaceFacet");

        // Deploy FortyAcresMarketplaceFacet (buyer-side: buy from other 40 Acres portfolios)
        FortyAcresMarketplaceFacet fortyAcresFacet = new FortyAcresMarketplaceFacet(address(portfolioFactory), VOTING_ESCROW, MARKETPLACE);
        bytes4[] memory fortyAcresSelectors = new bytes4[](1);
        fortyAcresSelectors[0] = FortyAcresMarketplaceFacet.buyFortyAcresListing.selector;
        // _registerFacet(facetRegistry, address(fortyAcresFacet), fortyAcresSelectors, "FortyAcresMarketplaceFacet");

        // Deploy OpenXFacet
        OpenXFacet openXFacet = new OpenXFacet(address(portfolioFactory), VOTING_ESCROW);
        bytes4[] memory openXSelectors = new bytes4[](1);
        openXSelectors[0] = OpenXFacet.buyOpenXListing.selector;
        // _registerFacet(facetRegistry, address(openXFacet), openXSelectors, "OpenXFacet");

        // Deploy VexyFacet
        VexyFacet vexyFacet = new VexyFacet(address(portfolioFactory), VOTING_ESCROW);
        bytes4[] memory vexySelectors = new bytes4[](1);
        vexySelectors[0] = VexyFacet.buyVexyListing.selector;
        // _registerFacet(facetRegistry, address(vexyFacet), vexySelectors, "VexyFacet");
    }

}

contract WalletUpgrade is PortfolioFactoryConfigDeploy {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address public constant MARKETPLACE = 0x7b22D5D5753B76B5AAF2cC0ac11457e069b9f2C8;

    PortfolioManager public constant PORTFOLIO_MANAGER = PortfolioManager(0x5f3736D7686edb3F74c0726D8fDF3f58252cC1F9);
    bytes32 public constant WALLET_SALT = bytes32(keccak256(abi.encodePacked("wallet")));

    address public constant PORTFOLIO_ACCOUNT_CONFIG = 0xd9b2c0927eaBCa49076D9286D2b83B67fe8c55C7;
    address public constant SWAP_CONFIG = 0x3646C436f18f0e2E38E10D1A147f901a96BD4390;

    function run() external {
        address walletFactory = PORTFOLIO_MANAGER.factoryBySalt(WALLET_SALT);
        require(walletFactory != address(0), "Wallet factory not deployed for salt");

        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));

        PortfolioFactory portfolioFactory = PortfolioFactory(walletFactory);
        FacetRegistry facetRegistry = portfolioFactory.facetRegistry();
        PortfolioFactoryConfig portfolioFactoryConfig = PortfolioFactoryConfig(PORTFOLIO_ACCOUNT_CONFIG);
        SwapConfig swapConfig = SwapConfig(SWAP_CONFIG);

        // Deploy WalletFacet
        // WalletFacet walletFacet = new WalletFacet(address(portfolioFactory), address(swapConfig));
        // bytes4[] memory walletSelectors = new bytes4[](6);
        // walletSelectors[0] = WalletFacet.transferERC20.selector;
        // walletSelectors[1] = WalletFacet.transferNFT.selector;
        // walletSelectors[2] = WalletFacet.receiveERC20.selector;
        // walletSelectors[3] = WalletFacet.swap.selector;
        // walletSelectors[4] = WalletFacet.onERC721Received.selector;
        // walletSelectors[5] = WalletFacet.enforceCollateralRequirements.selector;
        // _registerFacet(facetRegistry, address(walletFacet), walletSelectors, "WalletFacet");

        // Deploy MarketplaceFacet (seller-side)
        // MarketplaceFacet marketplaceFacet = new MarketplaceFacet(address(portfolioFactory), VOTING_ESCROW, MARKETPLACE);
        // bytes4[] memory marketplaceSelectors = new bytes4[](6);
        // marketplaceSelectors[0] = BaseMarketplaceFacet.makeListing.selector;
        // marketplaceSelectors[1] = BaseMarketplaceFacet.cancelListing.selector;
        // marketplaceSelectors[2] = BaseMarketplaceFacet.receiveSaleProceeds.selector;
        // marketplaceSelectors[3] = BaseMarketplaceFacet.marketplace.selector;
        // marketplaceSelectors[4] = BaseMarketplaceFacet.getSaleAuthorization.selector;
        // marketplaceSelectors[5] = BaseMarketplaceFacet.hasSaleAuthorization.selector;
        // _registerFacet(facetRegistry, address(marketplaceFacet), marketplaceSelectors, "MarketplaceFacet");

        // Deploy FortyAcresMarketplaceFacet (buyer-side)
        FortyAcresMarketplaceFacet fortyAcresFacet = new FortyAcresMarketplaceFacet(address(portfolioFactory), VOTING_ESCROW, MARKETPLACE);
        bytes4[] memory fortyAcresSelectors = new bytes4[](1);
        fortyAcresSelectors[0] = FortyAcresMarketplaceFacet.buyFortyAcresListing.selector;
        _registerFacet(facetRegistry, address(fortyAcresFacet), fortyAcresSelectors, "FortyAcresMarketplaceFacet");

        // Deploy OpenXFacet
        // OpenXFacet openXFacet = new OpenXFacet(address(portfolioFactory), VOTING_ESCROW);
        // bytes4[] memory openXSelectors = new bytes4[](1);
        // openXSelectors[0] = OpenXFacet.buyOpenXListing.selector;
        // _registerFacet(facetRegistry, address(openXFacet), openXSelectors, "OpenXFacet");

        // Deploy VexyFacet
        // VexyFacet vexyFacet = new VexyFacet(address(portfolioFactory), VOTING_ESCROW);
        // bytes4[] memory vexySelectors = new bytes4[](1);
        // vexySelectors[0] = VexyFacet.buyVexyListing.selector;
        // _registerFacet(facetRegistry, address(vexyFacet), vexySelectors, "VexyFacet");

        vm.stopBroadcast();
    }

}

// forge script script/portfolio_account/aerodrome/DeployWallet.s.sol:WalletDeploy --sig "run()" --rpc-url $BASE_RPC_URL --broadcast
// forge script script/portfolio_account/aerodrome/DeployWallet.s.sol:WalletUpgrade --sig "run()" --rpc-url $BASE_RPC_URL --broadcast