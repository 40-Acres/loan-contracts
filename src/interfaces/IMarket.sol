// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {ILoan} from "./ILoan.sol";

interface IMarket {
    // ============ STRUCTS ============
    
    struct Listing {
        address owner;                    // LoanV2.borrower
        uint256 tokenId;
        uint256 price;                    // in paymentToken decimals
        address paymentToken;             // whitelisted token
        bool hasOutstandingLoan;          // if true, buyer must also pay current loan balance
        uint256 expiresAt;                // 0 = never
    }

    struct Offer {
        address creator;                   // offer creator
        uint256 minWeight;                // minimum acceptable veNFT weight
        uint256 debtTolerance;            // max acceptable loan balance
        uint256 price;                     // offer price in paymentToken
        address paymentToken;              // whitelisted token
        uint256 expiresAt;                // 0 = never
        uint256 offerId;                  // unique offer identifier
    }

    // ============ EVENTS ============
    
    event ListingCreated(uint256 indexed tokenId, address indexed owner, uint256 price, address paymentToken, bool hasOutstandingLoan, uint256 expiresAt);
    event ListingUpdated(uint256 indexed tokenId, uint256 price, address paymentToken, uint256 expiresAt);
    event ListingCancelled(uint256 indexed tokenId);
    event ListingTaken(uint256 indexed tokenId, address indexed buyer, uint256 price, uint256 fee);
    event OfferCreated(uint256 indexed offerId, address indexed creator, uint256 minWeight, uint256 debtTolerance, uint256 price, address paymentToken, uint256 expiresAt);
    event OfferUpdated(uint256 indexed offerId, uint256 newMinWeight, uint256 newDebtTolerance, uint256 newPrice, address newPaymentToken, uint256 newExpiresAt);
    event OfferCancelled(uint256 indexed offerId);
    event OfferAccepted(uint256 indexed offerId, uint256 indexed tokenId, address indexed seller, uint256 price, uint256 fee);
    event OfferMatched(uint256 indexed offerId, uint256 indexed tokenId, address indexed buyer, uint256 price, uint256 fee);
    event OperatorApproved(address indexed owner, address indexed operator, bool approved);
    event PaymentTokenAllowed(address indexed token, bool allowed);
    event MarketFeeChanged(uint16 newBps);
    event FeeRecipientChanged(address newRecipient);

    // ============ EXTERNAL FUNCTIONS ============
    
    // Listing management
    function makeListing(
        uint256 tokenId, 
        uint256 price, 
        address paymentToken, 
        uint256 expiresAt
    ) external;
    
    function updateListing(
        uint256 tokenId, 
        uint256 newPrice, 
        address newPaymentToken, 
        uint256 newExpiresAt
    ) external;
    
    function cancelListing(uint256 tokenId) external;
    
    // Purchase paths
    function takeListing(uint256 tokenId) external payable;
    
    // Offer management
    function createOffer(
        uint256 minWeight,
        uint256 debtTolerance,
        uint256 price,
        address paymentToken,
        uint256 expiresAt
    ) external payable;
    
    function updateOffer(
        uint256 offerId,
        uint256 newMinWeight,
        uint256 newDebtTolerance,
        uint256 newPrice,
        address newPaymentToken,
        uint256 newExpiresAt
    ) external;
    
    function cancelOffer(uint256 offerId) external;
    
    function acceptOffer(uint256 tokenId, uint256 offerId, bool isInLoanV2, uint256 expectedPrice, address expectedPaymentToken) external;
    
    function matchOfferWithListing(uint256 offerId, uint256 tokenId) external;
    
    // Operator management
    function setOperatorApproval(address operator, bool approved) external;
    
    // ============ VIEW FUNCTIONS ============
    
    function getListing(uint256 tokenId) external view returns (
        address owner,
        uint256 price,
        address paymentToken,
        bool hasOutstandingLoan,
        uint256 expiresAt
    );
    
    function getOffer(uint256 offerId) external view returns (
        address creator,
        uint256 minWeight,
        uint256 debtTolerance,
        uint256 price,
        address paymentToken,
        uint256 expiresAt
    );
    
    function isListingActive(uint256 tokenId) external view returns (bool);
    
    function isOfferActive(uint256 offerId) external view returns (bool);
    
    function canOperate(address owner, address operator) external view returns (bool);
    
    // ============ PUBLIC STATE GETTERS ============
    
    function loan() external view returns (address);
    
    function marketFeeBps() external view returns (uint16);
    
    function feeRecipient() external view returns (address);
    
    function isOperatorFor(address owner, address operator) external view returns (bool);
    
    function allowedPaymentToken(address token) external view returns (bool);
    
    // ============ ADMIN FUNCTIONS ============
    
    function setMarketFee(uint16 bps) external;
    
    function setFeeRecipient(address recipient) external;
    
    function setAllowedPaymentToken(address token, bool allowed) external;
    
    function pause() external;
    
    function unpause() external;
}
