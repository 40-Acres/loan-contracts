// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";
import {PortfolioFactoryConfigDeploy} from "../DeployPortfolioFactoryConfig.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WalletFacet} from "../../../src/facets/account/wallet/WalletFacet.sol";
import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {FortyAcresMarketplaceFacet} from "../../../src/facets/account/marketplace/FortyAcresMarketplaceFacet.sol";
import {OpenXFacet} from "../../../src/facets/account/marketplace/OpenXFacet.sol";
import {VexyFacet} from "../../../src/facets/account/marketplace/VexyFacet.sol";
import {SwapMod} from "../../../src/facets/account/swap/SwapMod.sol";
import {console} from "forge-std/console.sol";

contract WalletDeploy is PortfolioFactoryConfigDeploy {
    address public constant VOTING_ESCROW = 0x4C3e7640B3e3A39a2e5d030A0C1412d80FEE1D44;

    PortfolioFactory public _portfolioFactory;

    function run() external {
        vm.startBroadcast(vm.envUint("FORTY_ACRES_DEPLOYER"));
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        PortfolioManager _portfolioManager = PortfolioManager(PORTFOLIO_MANAGER_ADDRESS);
        address portfolioFactory = _portfolioManager.factoryBySalt(keccak256(abi.encodePacked("wallet")));
        require(portfolioFactory != address(0), "Wallet factory not deployed");
        FacetRegistry facetRegistry = PortfolioFactory(portfolioFactory).facetRegistry();

        // Use the Ethereum mainnet SwapConfig (shared with SuperNova deployment)
        SwapConfig swapConfig = SwapConfig(ETH_SWAP_CONFIG);

        // Deploy PortfolioFactoryConfig (deployer as initial owner so we can configure, then transfer)
        PortfolioFactoryConfig configImpl = _createConfigImpl();
        PortfolioFactoryConfig portfolioFactoryConfig = PortfolioFactoryConfig(
            address(new ERC1967Proxy(
                address(configImpl),
                abi.encodeCall(PortfolioFactoryConfig.initialize, (DEPLOYER_ADDRESS, portfolioFactory))
            ))
        );


        _portfolioFactory = PortfolioFactory(portfolioFactory);

        console.log("Deployed Wallet configs for factory at:", portfolioFactory);
        console.log("  PortfolioFactoryConfig:", address(portfolioFactoryConfig));
        console.log("  SwapConfig:", address(swapConfig));
        // setPortfolioFactoryConfig must be called by multisig (PM owner)
        console.log("=== Multisig Action Required ===");
        console.log("Call PortfolioFactory.setPortfolioFactoryConfig with:");
        console.log("  PortfolioFactory:", portfolioFactory);
        console.log("  PortfolioFactoryConfig:", address(portfolioFactoryConfig));

        // Deploy and register all facets
        _deployFacets(facetRegistry, PortfolioFactory(portfolioFactory), portfolioFactoryConfig, swapConfig);

        // transfer ownerships to multisig
        portfolioFactoryConfig.transferOwnership(MULTISIG_ADDRESS);
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
        _registerFacet(facetRegistry, address(walletFacet), walletSelectors, "WalletFacet");


        // Deploy FortyAcresMarketplaceFacet (buyer-side: buy from other 40 Acres portfolios)
        FortyAcresMarketplaceFacet fortyAcresFacet = new FortyAcresMarketplaceFacet(address(portfolioFactory), VOTING_ESCROW, VENOVA_MARKETPLACE);
        bytes4[] memory fortyAcresSelectors = new bytes4[](1);
        fortyAcresSelectors[0] = FortyAcresMarketplaceFacet.buyFortyAcresListing.selector;
        _registerFacet(facetRegistry, address(fortyAcresFacet), fortyAcresSelectors, "FortyAcresMarketplaceFacet");

        // // Deploy OpenXFacet
        // OpenXFacet openXFacet = new OpenXFacet(address(portfolioFactory), VOTING_ESCROW);
        // bytes4[] memory openXSelectors = new bytes4[](1);
        // openXSelectors[0] = OpenXFacet.buyOpenXListing.selector;
        // _registerFacet(facetRegistry, address(openXFacet), openXSelectors, "OpenXFacet");

        // // Deploy VexyFacet
        // VexyFacet vexyFacet = new VexyFacet(address(portfolioFactory), VOTING_ESCROW);
        // bytes4[] memory vexySelectors = new bytes4[](1);
        // vexySelectors[0] = VexyFacet.buyVexyListing.selector;
        // _registerFacet(facetRegistry, address(vexyFacet), vexySelectors, "VexyFacet");
    }

}

// forge script script/portfolio_account/aerodrome/DeployWallet.s.sol:WalletDeploy --chain-id 1 --rpc-url $ETH_RPC_URL --broadcast --verify --via-ir
// forge script script/portfolio_account/aerodrome/DeployWallet.s.sol:WalletUpgrade --sig "run()" --rpc-url $BASE_RPC_URL --broadcast