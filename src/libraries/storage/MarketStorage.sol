// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title MarketStorage
 * @dev Provides isolated storage structures for different market mechanisms
 * Each component has its own storage slot to prevent collisions
 */
library MarketStorage {
    // ============ Market structs ============
    struct Listing {
        address owner;                    // borrower at time of listing
        uint256 tokenId;
        uint256 price;                    // in paymentToken decimals
        address paymentToken;             // whitelisted token
        bool hasOutstandingLoan;          // if true, buyer must also pay current loan balance
        uint256 expiresAt;                // 0 = never
    }

    struct Offer {
        address creator;                  // offer creator
        uint256 minWeight;                // minimum acceptable veNFT weight
        uint256 maxWeight;                // maximum acceptable veNFT weight
        uint256 debtTolerance;            // max acceptable loan balance
        uint256 price;                    // offer price in paymentToken
        address paymentToken;             // whitelisted token
        uint256 expiresAt;                // 0 = never
        uint256 offerId;                  // unique offer identifier
    }
    // Storage positions - each component gets a unique storage slot

    bytes32 constant MARKET_PAUSE = keccak256("market.pause.storage");
    bytes32 constant MARKET_CONFIG = keccak256("market.config.storage");
    bytes32 constant ORDERBOOK_POSITION = keccak256("market.orderbook.storage");

    // Global configuration and guards
    // @custom:storage-location erc7201:market.pause.storage
    struct MarketPauseLayout {
        bool marketPaused;
        // Simple reentrancy guard status: 1 = NOT_ENTERED, 2 = ENTERED
        uint256 reentrancyStatus;
        uint256[48] _gap;
    }

    // @custom:storage-location erc7201:market.config.storage
    struct MarketConfigLayout {
        uint16 marketFeeBps;                                          // fee in basis points, max 1000 (10%)
        address feeRecipient;                                         // fee recipient address
        mapping(address => bool) allowedPaymentToken;                 // whitelisted payment tokens
        address loan;                                                 // ILoan address
        address votingEscrow;                                         // IVotingEscrow address
        address accessManager;                                        // AccessManager for role-based auth
        address loanAsset;                                            // payment asset expected by Loan for pay() (e.g., USDC)
        mapping(address => bool) allowedVotingEscrow;                 // allowed veNFT contracts
        mapping(bytes32 => address) externalAdapter;                  // adapterKey => adapter facet address
        address permit2;                                              // Uniswap Permit2 address (optional)
        uint256[49] _gap;
    }

    // @custom:storage-location erc7201:market.orderbook.storage
    struct MarketOrderbookLayout {
        mapping(address => mapping(address => bool)) isOperatorFor;   // owner => operator => approved
        // Listing-specific storage
        mapping(uint256 => Listing) listings;                         // tokenId => Listing
        // Offer-specific storage
        mapping(uint256 => Offer) offers;                             // offerId => Offer
        uint256 _offerCounter;                                        // auto-incrementing offer ID
        uint256[50] _gap;
    }

    function configLayout() internal pure returns (MarketConfigLayout storage l) {
        bytes32 position = MARKET_CONFIG;
        assembly {
            l.slot := position
        }
    }

    function managerPauseLayout() internal pure returns (MarketPauseLayout storage l) {
        bytes32 position = MARKET_PAUSE;
        assembly {
            l.slot := position
        }
    }

    function orderbookLayout() internal pure returns (MarketOrderbookLayout storage l) {
        bytes32 position = ORDERBOOK_POSITION;
        assembly {
            l.slot := position
        }
    }
}
