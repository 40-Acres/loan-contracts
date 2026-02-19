// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FortyAcresMarketplaceFacet} from "../../../src/facets/account/marketplace/FortyAcresMarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../src/facets/marketplace/PortfolioMarketplace.sol";
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PortfolioHelperUtils} from "../../utils/PortfolioHelperUtils.sol";

/**
 * @title BuyMarketplaceListing
 * @dev Helper script to buy a veNFT from the 40 Acres marketplace via wallet portfolio.
 *
 * The buyer must have a wallet portfolio with sufficient funds.
 * Uses FortyAcresMarketplaceFacet on the wallet factory to purchase listings.
 *
 * Usage:
 * forge script script/portfolio_account/helper/BuyMarketplaceListing.s.sol:BuyMarketplaceListing \
 *   --sig "run(address,uint256)" <SELLER_PORTFOLIO> <TOKEN_ID> --rpc-url $RPC_URL --broadcast
 */
contract BuyMarketplaceListing is Script {
    using stdJson for string;

    function buyMarketplaceListing(
        address sellerPortfolio,
        uint256 tokenId,
        address walletFactory
    ) internal {
        PortfolioManager portfolioManager = PortfolioHelperUtils.loadPortfolioManager(vm);

        // Get listing details from marketplace
        BaseMarketplaceFacet marketplaceFacet = BaseMarketplaceFacet(sellerPortfolio);
        address marketplaceAddr = marketplaceFacet.marketplace();
        PortfolioMarketplace marketplace = PortfolioMarketplace(marketplaceAddr);
        PortfolioMarketplace.Listing memory listing = marketplace.getListing(sellerPortfolio, tokenId);
        require(listing.owner != address(0), "Listing does not exist");

        console.log("Listing Details:");
        console.log("  Token ID:", tokenId);
        console.log("  Price:", listing.price);
        console.log("  Payment Token:", listing.paymentToken);

        // Buy via wallet factory multicall
        address[] memory factories = new address[](1);
        factories[0] = walletFactory;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(
            FortyAcresMarketplaceFacet.buyFortyAcresListing.selector,
            sellerPortfolio,
            tokenId,
            listing.nonce
        );
        portfolioManager.multicall(data, factories);

        console.log("Purchase successful!");
    }

    function run(
        address sellerPortfolio,
        uint256 tokenId
    ) external {
        address walletFactory = vm.envAddress("WALLET_FACTORY");
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);
        buyMarketplaceListing(sellerPortfolio, tokenId, walletFactory);
        vm.stopBroadcast();
    }
}
