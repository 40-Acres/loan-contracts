// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IMarketListingsWalletFacet {
    // Events
    event ListingCreated(uint256 indexed tokenId, address indexed owner, uint256 price, address paymentToken, bool hasOutstandingLoan, uint256 expiresAt);
    event ListingUpdated(uint256 indexed tokenId, uint256 price, address paymentToken, uint256 expiresAt);
    event ListingCancelled(uint256 indexed tokenId);
    event ListingTaken(uint256 indexed tokenId, address indexed buyer, uint256 price, uint256 fee);

    function makeWalletListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt
    ) external;

    function updateWalletListing(
        uint256 tokenId,
        uint256 newPrice,
        address newPaymentToken,
        uint256 newExpiresAt
    ) external;

    function cancelWalletListing(uint256 tokenId) external;

    // Admin-only: cancel a batch of expired wallet listings
    function cancelExpiredWalletListings(uint256[] calldata listingIds) external;

    // Single entry: direct or Odos swap depending on parameters
    // - No swap: inputToken == paymentToken and tradeData.length == 0
    // - Swap via Odos: inputToken != paymentToken and tradeData.length > 0
    // - Permit2 optional: encode PermitSingle + signature in optionalPermit2
    struct TokenPermissions { address token; uint256 amount; }
    struct PermitSingle { TokenPermissions permitted; uint256 nonce; uint256 deadline; address spender; }
    function takeWalletListing(
        uint256 tokenId,
        address inputToken,
        uint256 amountInMax,
        bytes calldata tradeData,
        bytes calldata optionalPermit2
    ) external payable;

    // Router-only entry that allows the router to pass the buyer explicitly
    // This must only be callable via the diamond itself
    function takeWalletListingFor(
        uint256 tokenId,
        address buyer,
        address inputToken,
        uint256 amountInMax,
        bytes calldata tradeData,
        bytes calldata optionalPermit2
    ) external payable;

    function quoteWalletListing(
        uint256 tokenId
    ) external view returns (
        uint256 listingPriceInPaymentToken,
        uint256 protocolFeeInPaymentToken,
        address paymentToken
    );
}


