// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IOpenXAdapterFacet} from "../../interfaces/IOpenXAdapterFacet.sol";
import {BaseAdapterFacet} from "./BaseAdapterFacet.sol";
import {MarketStorage} from "../../libraries/storage/MarketStorage.sol";
import {IMarketConfigFacet} from "../../interfaces/IMarketConfigFacet.sol";
import {IOpenXSwap} from "../../interfaces/external/IOpenXSwap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Permit2Lib} from "../../libraries/Permit2Lib.sol";
import {Errors} from "../../libraries/Errors.sol";

contract OpenXAdapterFacet is IOpenXAdapterFacet, BaseAdapterFacet {
    modifier whenNotPaused() {
        if (MarketStorage.managerPauseLayout().marketPaused) revert("Paused");
        _;
    }

    modifier onlyDiamond() {
        if (msg.sender != address(this)) revert("NotAuthorized");
        _;
    }

    function takeOpenXListing(
        address marketplace,
        uint256 listingId,
        address expectedCurrency,
        uint256 maxPrice
    ) external whenNotPaused onlyDiamond {
        require(marketplace != address(0), "Invalid marketplace");

        IOpenXSwap openx = IOpenXSwap(marketplace);
        (
            address veNft,
            ,
            ,
            uint256 nftId,
            address currency,
            ,
            ,
            ,
            uint256 sold
        ) = openx.Listings(listingId);
        require(sold == 0, "Listing sold");

        // Currency must be allowed and match expectation
        if (!MarketStorage.configLayout().allowedPaymentToken[currency]) revert("CurrencyNotAllowed");
        require(currency == expectedCurrency, "CurrencyMismatch");

        // OpenX listings are fixed-price per Listings() (price returned), use that
        (, , , , , uint256 price, , ,) = openx.Listings(listingId);
        require(price > 0 && (maxPrice == 0 || price <= maxPrice), "PriceOutOfBounds");

        // Pull funds into diamond and approve marketplace
        IERC20 payToken = IERC20(currency);
        if (msg.sender != address(this)) {
            require(payToken.transferFrom(msg.sender, address(this), price), "TransferFrom failed");
        } else {
            require(payToken.balanceOf(address(this)) >= price, "EscrowInsufficient");
        }
        payToken.approve(marketplace, price);

        // Execute purchase, NFT will be sent to this diamond
        openx.buyNFT(listingId);

        // Forward NFT to buyer (delegatecall preserves the original caller as msg.sender)
        IERC721(veNft).transferFrom(address(this), msg.sender, nftId);

        emit OpenXListingPurchased(marketplace, listingId, veNft, nftId, msg.sender, currency, price);
    }

    // ============ Generic adapter ABI used by MarketRouterFacet ==========
    // quoteData = abi.encode(address marketplace, uint256 listingId)
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
        IOpenXSwap openx = IOpenXSwap(marketplace);
        (
            ,
            ,
            ,
            ,
            address currency,
            uint256 price,
            ,
            ,
            uint256 sold
        ) = openx.Listings(listingId);
        require(sold == 0, "Listing sold");
        uint16 bps = _externalRouteFeeBps();
        uint256 fee = (price * bps) / 10000;
        return (price, fee, currency);
    }

    function buyToken(
        uint256 tokenId,
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

        require(marketplace != address(0), "Invalid marketplace");
        IOpenXSwap openx = IOpenXSwap(marketplace);

        (
            address veNft,
            ,
            ,
            uint256 nftId,
            address currency,
            uint256 price,
            ,
            ,
            uint256 sold
        ) = openx.Listings(listingId);
        // require this listing tokenid is the same tokenid as one passed in 
        require(nftId == tokenId, "TokenIdMismatch");
        require(sold == 0, "Listing sold");
        if (!MarketStorage.configLayout().allowedPaymentToken[currency]) revert("CurrencyNotAllowed");
        require(currency == expectedCurrency, "CurrencyMismatch");
        require(price > 0 && (maxPrice == 0 || price <= maxPrice), "PriceOutOfBounds");

        uint16 bps = _externalRouteFeeBps();
        uint256 fee = (price * bps) / 10000;
        uint256 total = price + fee;
        require(total <= maxTotal, "MaxTotalExceeded");

        IERC20 payToken = IERC20(currency);
        address feeRecipient_ = MarketStorage.configLayout().feeRecipient;

        // Exact-input strategy: no refund bookkeeping

        if (tradeData.length == 0 && inputToken == currency) {
            // Direct currency path: pull exact total in currency
            Permit2Lib.permitAndPull(msg.sender, address(this), currency, total, optionalPermit2);
            if (optionalPermit2.length == 0) {
                if (msg.sender != address(this)) {
                    require(payToken.transferFrom(msg.sender, address(this), total), "TransferFrom failed");
                } else {
                    require(payToken.balanceOf(address(this)) >= total, "EscrowInsufficient");
                }
            }
        } else {
            // Swap path via ODOS. Support native ETH or ERC20 input.
            address odos = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;
            if (inputToken == address(0)) {
                // ETH-in path
                require(msg.value > 0, "InsufficientETH");
                (bool success,) = odos.call{value: msg.value}(tradeData);
                require(success, "ODOS swap failed");
                require(payToken.balanceOf(address(this)) >= total, "Slippage");
            } else {
                // ERC20-in path: pull max input via Permit2 if provided upstream; otherwise fallback
                Permit2Lib.permitAndPull(msg.sender, address(this), inputToken, amountInMax, optionalPermit2);
                if (optionalPermit2.length == 0 && IERC20(inputToken).balanceOf(address(this)) < amountInMax) {
                    require(IERC20(inputToken).transferFrom(msg.sender, address(this), amountInMax), "TransferFrom failed");
                }
                IERC20(inputToken).approve(odos, amountInMax);
                (bool success2,) = odos.call{value: 0}(tradeData);
                require(success2, "ODOS swap failed");
                IERC20(inputToken).approve(odos, 0);
                require(payToken.balanceOf(address(this)) >= total, "Slippage");
            }
        }

        // Settle fee, approve and buy
        if (fee > 0) {
            require(payToken.transfer(feeRecipient_, fee), "Fee transfer failed");
        }
        payToken.approve(marketplace, price);
        openx.buyNFT(listingId);

        // Forward NFT to buyer (delegatecall preserves the original caller as msg.sender)
        IERC721(veNft).transferFrom(address(this), msg.sender, nftId);

        emit OpenXListingPurchased(marketplace, listingId, veNft, nftId, msg.sender, currency, price);
    }
}


