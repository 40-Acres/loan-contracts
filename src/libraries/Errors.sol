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

    // Matching / orderbook
    error OfferNotFound();
    error ListingNotFound();
    error OfferExpired();
    error ListingExpired();
    error LoanListingNotAllowed();

    // External adapters
    error WrongMarketVotingEscrow();
    error ListingInactive();
    error CurrencyNotAllowed();
    error PriceOutOfBounds();
    error OfferTooLow();
    error UnknownExternalMarket();

    // Validation
    error InsufficientWeight();
    error ExcessiveWeight();
    error InsufficientDebtTolerance();
    error ExcessiveLockTime();

    // Settlement / swaps / custody
    error Slippage();
    error DebtNotCleared();
    error BadCustody();
}


