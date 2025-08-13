// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVexyAdapterFacet} from "../../interfaces/IVexyAdapterFacet.sol";
import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {IMarketConfigFacet} from "../../interfaces/IMarketConfigFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVexyMarketplace} from "../../interfaces/external/IVexyMarketplace.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract VexyAdapterFacet is IVexyAdapterFacet {
    modifier whenNotPaused() {
        if (MarketStorage.managerPauseLayout().marketPaused) revert("Paused");
        _;
    }

    /// @inheritdoc IVexyAdapterFacet
    function buyVexyListing(
        address marketplace,
        uint256 listingId,
        address expectedCurrency,
        uint256 maxPrice
    ) external whenNotPaused {
        // Validate marketplace address
        require(marketplace != address(0), "Invalid marketplace");

        // Fetch listing details and current dynamic price
        IVexyMarketplace vexy = IVexyMarketplace(marketplace);
        (
            address seller_,
            uint96 sellerNftNonce_,
            address nftCollection,
            uint256 nftId,
            address currency,
            uint96 slopeMax_,
            uint256 basePrice_,
            uint32 slopeDuration_,
            uint32 fixedDuration_,
            uint64 endTime,
            uint64 soldTime
        ) = vexy.listings(listingId);
        require(soldTime == 0, "Listing sold");
        require(endTime >= block.timestamp, "Listing expired");

        // Currency must be allowed by our market and match caller's expectation
        if (!MarketStorage.configLayout().allowedPaymentToken[currency]) revert("CurrencyNotAllowed");
        require(currency == expectedCurrency, "CurrencyMismatch");

        uint256 price = vexy.listingPrice(listingId);
        require(price > 0 && price <= maxPrice, "PriceOutOfBounds");

        // Pull funds from buyer into this diamond, then approve Vexy and buy
        IERC20 payToken = IERC20(currency);
        if (msg.sender != address(this)) {
            require(payToken.transferFrom(msg.sender, address(this), price), "TransferFrom failed");
        } else {
            require(payToken.balanceOf(address(this)) >= price, "EscrowInsufficient");
        }
        payToken.approve(marketplace, price);

        // Perform the purchase; Vexy will take fee and pay seller; NFT will move to this diamond
        vexy.buyListing(listingId);

        // Forward NFT to the buyer
        IERC721(nftCollection).transferFrom(address(this), msg.sender, nftId);

        emit VexyListingPurchased(marketplace, listingId, nftCollection, nftId, msg.sender, currency, price);
    }
}


