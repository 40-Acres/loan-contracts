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
import {Permit2Lib} from "../../libraries/Permit2Lib.sol";

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
        // Validate marketplace address
        require(marketplace != address(0), Errors.InvalidExternalMarketplace());

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
        require(soldTime == 0, Errors.ListingSold());
        require(endTime >= block.timestamp, Errors.ListingExpired());

        // Currency must be allowed by our market and match caller's expectation
        if (!MarketStorage.configLayout().allowedPaymentToken[currency]) revert Errors.CurrencyNotAllowed();
        require(currency == expectedCurrency, Errors.CurrencyMismatch());

        uint256 price = vexy.listingPrice(listingId);
        require(price > 0 && price <= maxPrice, Errors.PriceOutOfBounds());

        // Pull funds from buyer into this diamond, then approve Vexy and buy
        IERC20 payToken = IERC20(currency);
        if (msg.sender != address(this)) {
            require(payToken.transferFrom(msg.sender, address(this), price));
        } else {
            require(payToken.balanceOf(address(this)) >= price, Errors.EscrowInsufficient());
        }
        payToken.approve(marketplace, price);

        // Perform the purchase; Vexy will take fee and pay seller; NFT will move to this diamond
        vexy.buyListing(listingId);

        // Forward NFT to the buyer (delegatecall path from router preserves buyer in msg.sender)
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
        require(marketplace != address(0), Errors.InvalidExternalMarketplace());
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
        require(soldTime == 0, Errors.ListingSold());
        uint256 price = vexy.listingPrice(listingId);
        uint16 bps = _externalRouteFeeBps();
        uint256 fee = (price * bps) / 10000;
        return (price, fee, currency);
    }

    // Uniform external adapter ABI
    // For Vexy, marketData = abi.encode(address marketplace, uint256 listingId, address expectedCurrency, uint256 maxPrice)
    function buyToken(
        uint256 /*tokenId*/,
        uint256 maxTotal,
        address inputToken,
        uint256 amountInMax,
        bytes calldata tradeData,
        bytes calldata marketData,
        bytes calldata optionalPermit2
    ) external payable override whenNotPaused {
        (address marketplace, uint256 listingId, address expectedCurrency, uint256 maxPrice) = abi.decode(
            marketData, (address, uint256, address, uint256)
        );

        // Validate marketplace and fetch listing/currency/price
        require(marketplace != address(0), Errors.InvalidExternalMarketplace());
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
        require(soldTime == 0, Errors.ListingSold());
        if (!MarketStorage.configLayout().allowedPaymentToken[currency]) revert Errors.CurrencyNotAllowed();
        require(currency == expectedCurrency, Errors.CurrencyMismatch());

        uint256 price = vexy.listingPrice(listingId);
        require(price > 0 && (maxPrice == 0 || price <= maxPrice), Errors.PriceOutOfBounds());

        // Compute external route fee and bound total
        uint16 bps = _externalRouteFeeBps();
        uint256 fee = (price * bps) / 10000;
        uint256 total = price + fee;
        require(total <= maxTotal, Errors.MaxTotalExceeded());

        // Handle fund collection and optional swap via ODOS
        address feeRecipient_ = MarketStorage.configLayout().feeRecipient;
        IERC20 payToken = IERC20(currency);
        if (tradeData.length == 0 && inputToken == currency) {
            // Direct currency path: pull exact total in currency
            // First try Permit2 if provided; fallback to transferFrom
            Permit2Lib.permitAndPull(msg.sender, address(this), currency, total, optionalPermit2);
            if (optionalPermit2.length == 0) {
                if (msg.sender != address(this)) {
                    require(payToken.transferFrom(msg.sender, address(this), total));
                } else {
                    require(payToken.balanceOf(address(this)) >= total, Errors.EscrowInsufficient());
                }
            }
        } else {
            // Swap path via ODOS. Support native ETH or ERC20 input.
            address odos = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;
            if (inputToken == address(0)) {
                // ETH-in path
                require(msg.value > 0, Errors.InsufficientETH());
                (bool success,) = odos.call{value: msg.value}(tradeData);
                require(success, Errors.OdosFailed());
                // Ensure enough currency to cover total
                require(payToken.balanceOf(address(this)) >= total, Errors.Slippage());
            } else {
                // ERC20-in path
                // Pull max input via Permit2 if provided upstream; otherwise fallback
                Permit2Lib.permitAndPull(msg.sender, address(this), inputToken, amountInMax, optionalPermit2);
                if (optionalPermit2.length == 0 && IERC20(inputToken).balanceOf(address(this)) < amountInMax) {
                    require(IERC20(inputToken).transferFrom(msg.sender, address(this), amountInMax));
                }
                IERC20(inputToken).approve(odos, amountInMax);
                (bool success2,) = odos.call{value: 0}(tradeData);
                require(success2, Errors.OdosFailed());
                IERC20(inputToken).approve(odos, 0);
                // Ensure enough currency to cover total
                require(payToken.balanceOf(address(this)) >= total, Errors.Slippage());
            }
        }

        // Settle fee, approve Vexy for price, execute purchase
        if (fee > 0) {
            require(payToken.transfer(feeRecipient_, fee));
        }
        payToken.approve(marketplace, price);
        IVexyMarketplace(marketplace).buyListing(listingId);

        // Forward NFT to buyer (delegatecall path preserves buyer in msg.sender)
        (,, address nftCollection, uint256 nftId,, , , , , ,) = IVexyMarketplace(marketplace).listings(listingId);
        IERC721(nftCollection).transferFrom(address(this), msg.sender, nftId);
    }
}


