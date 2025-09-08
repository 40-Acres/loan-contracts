// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

library Errors {
    error NotAuthorized();
    error ZeroAddress();
    error AlreadyInitialized();
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

    // External adapters
    error WrongMarketVotingEscrow();
    error ListingInactive();
    error CurrencyNotAllowed();
    error PriceOutOfBounds();
    error OfferTooLow();
    error UnknownAdapter();
    error MaxTotalExceeded();

    // Validation
    error InsufficientWeight();
    error ExcessiveWeight();
    error InsufficientDebtTolerance();
    error InvalidExpiration();

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
}


