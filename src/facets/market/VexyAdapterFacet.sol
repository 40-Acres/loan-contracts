// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVexyAdapterFacet} from "../../interfaces/IVexyAdapterFacet.sol";
import {BaseAdapterFacet} from "./BaseAdapterFacet.sol";
import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {IMarketConfigFacet} from "../../interfaces/IMarketConfigFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVexyMarketplace} from "../../interfaces/external/IVexyMarketplace.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Errors} from "../../libraries/Errors.sol";

contract VexyAdapterFacet is IVexyAdapterFacet, BaseAdapterFacet {
    modifier whenNotPaused() {
        if (MarketStorage.managerPauseLayout().marketPaused) revert("Paused");
        _;
    }

    modifier onlyDiamond() {
        if (msg.sender != address(this)) revert Errors.NotAuthorized();
        _;
    }

    /// @inheritdoc IVexyAdapterFacet
    function takeVexyListing(
        address marketplace,
        uint256 listingId,
        address expectedCurrency,
        uint256 maxPrice
    ) external whenNotPaused onlyDiamond {
        // TODO: CONSIDER better gating for this function
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

    // ============ Generic adapter ABI for MarketRouterFacet ==========
    // quoteData abi-encoded as: (address marketplace, uint256 listingId)
    function quoteToken(
        uint256 /*tokenId*/,
        bytes calldata quoteData
    ) external view override returns (
        uint256 listingPriceInPaymentToken,
        uint256 protocolFeeInPaymentToken,
        address paymentToken
    ) {
        (address marketplace, uint256 listingId) = abi.decode(quoteData, (address, uint256));
        require(marketplace != address(0), "Invalid marketplace");
        IVexyMarketplace vexy = IVexyMarketplace(marketplace);
        (
            ,
            ,
            ,
            ,
            address currency,
            ,
            ,
            ,
            ,
            ,
            uint64 soldTime
        ) = vexy.listings(listingId);
        require(soldTime == 0, "Listing sold");
        uint256 price = vexy.listingPrice(listingId);
        uint16 bps = _externalRouteFeeBps();
        uint256 fee = (price * bps) / 10000;
        return (price, fee, currency);
    }

    // buyData abi-encoded as: (address marketplace, uint256 listingId, address expectedCurrency)
    function buyToken(
        uint256 /*tokenId*/,
        uint256 maxTotal,
        bytes calldata buyData,
        bytes calldata /*optionalPermit2*/
    ) external override whenNotPaused {
        (address marketplace, uint256 listingId, address expectedCurrency) = abi.decode(buyData, (address, uint256, address));

        // Quote to compute fee + validate currency; ensure total within bound
        (uint256 price, uint256 fee, address currency) = this.quoteToken(0, abi.encode(marketplace, listingId));
        require(currency == expectedCurrency, "CurrencyMismatch");
        uint256 total = price + fee;
        require(total <= maxTotal, "MaxTotalExceeded");

        // Pull funds for total; forward fee to recipient, approve marketplace with price, then buy
        IERC20 payToken = IERC20(currency);
        if (msg.sender != address(this)) {
            require(payToken.transferFrom(msg.sender, address(this), total), "TransferFrom failed");
        } else {
            require(payToken.balanceOf(address(this)) >= total, "EscrowInsufficient");
        }

        address feeRecipient_ = MarketStorage.configLayout().feeRecipient;
        if (fee > 0) {
            require(payToken.transfer(feeRecipient_, fee), "Fee transfer failed");
        }

        payToken.approve(marketplace, price);
        IVexyMarketplace(marketplace).buyListing(listingId);

        // Forward NFT to buyer
        (,, address nftCollection, uint256 nftId,, , , , , ,) = IVexyMarketplace(marketplace).listings(listingId);
        IERC721(nftCollection).transferFrom(address(this), msg.sender, nftId);
    }
}


