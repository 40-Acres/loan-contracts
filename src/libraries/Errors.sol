// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

library Errors {
    error NotAuthorized();
    error ZeroAddress();
    error AlreadyInitialized();
    error InvalidFee();

    // Common guards
    error Paused();
    error Reentrancy();
    error NotImplemented();
    error InvalidRoute();
    error NoTradeData();

    // Matching / orderbook
    error OfferNotFound();
    error ListingNotFound();
    error OfferExpired();
    error ListingExpired();
    error LoanListingNotAllowed();
    error InLoanCustody();
    error NotAllowedBuyer();
    error TokenNotApproved();

    // External adapters
    error WrongMarketVotingEscrow();
    error ListingInactive();
    error CurrencyNotAllowed();
    error PriceOutOfBounds();
    error OfferTooLow();
    error UnknownAdapter();
    error MaxTotalExceeded();
    error InvalidAdapterKey();
    error CallFailedWithNoData();

    // Validation
    error InsufficientWeight();
    error ExcessiveWeight();
    error InsufficientDebtTolerance();
    error InvalidExpiration();
    error InvalidTokenId();
    error InvalidPaymentToken();

    // Settlement / swaps / custody
    error Slippage();
    error DebtNotCleared();
    error BadCustody();
    error InputTokenNotAllowed();
    error NoETHForTokenPayment();
    error InsufficientETH();
    error SwapNotConfigured();
    error Permit2NotSet();
    error NoValidRoute();
    error WrongPaymentAsset();
    error LoanNotConfigured();
    error OdosFailed();

    // flash loan / LBO
    error InvalidFlashLoanCaller();
    error FlashLoanAssetMustMatchPurchaseAsset();
    error UserAssetMustMatchPurchaseAsset();
    error InsufficientBalanceForPurchase();
}


