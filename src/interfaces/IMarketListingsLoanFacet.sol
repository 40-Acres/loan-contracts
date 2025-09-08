// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IMarketListingsLoanFacet {
    // Events
    event ListingCreated(uint256 indexed tokenId, address indexed owner, uint256 price, address paymentToken, bool hasOutstandingLoan, uint256 expiresAt, address allowedBuyer);
    event ListingUpdated(uint256 indexed tokenId, uint256 price, address paymentToken, uint256 expiresAt, address allowedBuyer);
    event ListingCancelled(uint256 indexed tokenId);
    event ListingTaken(uint256 indexed tokenId, address indexed buyer, uint256 price, uint256 fee);

    function makeLoanListing(
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiresAt,
        address allowedBuyer
    ) external;

    function updateLoanListing(
        uint256 tokenId,
        uint256 newPrice,
        address newPaymentToken,
        uint256 newExpiresAt,
        address newAllowedBuyer
    ) external;

    function cancelLoanListing(uint256 tokenId) external;

    // Admin-only: cancel a batch of expired loan listings
    function cancelExpiredLoanListings(uint256[] calldata listingIds) external;

    function quoteLoanListing(
        uint256 tokenId,
        address inputToken
    ) external view returns (
        uint256 listingPriceInPaymentToken,
        uint256 protocolFeeInPaymentToken,
        uint256 requiredInputTokenAmount,
        address paymentToken
    );

    function takeLoanListing(
        uint256 tokenId,
        address inputToken,
        uint256 amountInMax,
        bytes calldata tradeData,
        bytes calldata optionalPermit2
    ) external payable;

    // Router-only entry allowing explicit buyer forwarding
    function takeLoanListingFor(
        uint256 tokenId,
        address buyer,
        address inputToken,
        uint256 amountInMax,
        bytes calldata tradeData,
        bytes calldata optionalPermit2
    ) external payable;

    // Optional Permit2 wrapper (parity with wallet facet)
    struct TokenPermissions { address token; uint256 amount; }
    struct PermitSingle { TokenPermissions permitted; uint256 nonce; uint256 deadline; address spender; }
    function takeLoanListingWithPermit(uint256 tokenId, address inputToken, PermitSingle calldata permitSingle, bytes calldata signature) external payable;
}


