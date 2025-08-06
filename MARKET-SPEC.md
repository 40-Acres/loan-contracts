# Market Contract Specification

## Overview
The **Market** contract allows users to list and purchase **veNFTs** that are used as collateral in the `LoanV2` lending system.  Purchases can occur when the veNFT has:
1. **No outstanding loan**
2. **Outstanding loan paid by the buyer** (from wallet)

All veNFT custody remains inside `LoanV2`; the Market only orchestrates loan settlement, ownership transfer, price settlement, and fee collection.

The contract is **upgradeable (UUPS)**, **pausable**, and protected by **ReentrancyGuard**.

## Required LoanV2 Changes
Market contract now uses `setBorrower()` function which already exists in LoanV2. The contract must be approved via `setApprovedContract(address(market), true)`.

---

## Contract Architecture of Market.sol

The Market contract follows the **ERC-7201 namespaced storage pattern** to ensure upgrade safety:

```solidity
contract Market is 
    IMarket, 
    Initializable, 
    UUPSUpgradeable, 
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable,
    MarketStorage
```

- **MarketStorage**: Contains all upgradeable state in namespaced storage slots
- **Immutable variables**: `_loan` and `_votingEscrow` addresses set in constructor

---

## Roles & Permissions
| Role | Abilities |
|------|-----------|
| **Owner** (`Ownable2StepUpgradeable`) | • pause/unpause<br/>• set `marketFeeBps` & `feeRecipient`<br/>• manage allowed payment tokens<br/>• upgrade contract |
| **Seller (listing owner)** | create / update / cancel their own listings |
| **Approved Operator** | on-chain operator authorised by seller via `setOperatorApproval` (similar to ERC-721 `setApprovalForAll`) that can manage all listings for that owner |
| **Buyer** | takes listings through any of the supported paths |

> Future optimisation: off-chain signature listings (à-la Seaport) can be added without storage changes, replacing on-chain operator approvals.

---

## Upgradeability & Pausability
* Inherits `UUPSUpgradeable` – upgrades authorised by `owner`.
* Inherits `PausableUpgradeable` – all state-changing user functions are guarded by `whenNotPaused`.
* Inherits `ReentrancyGuardUpgradeable` – external functions performing transfers are `nonReentrant`.

---

## State Variables
```solidity
// Stored in MarketStorage using ERC-7201 namespaced storage
struct MarketStorageStruct {
    uint16 marketFeeBps;                                          // fee in basis points, max 1000 (10%)
    address feeRecipient;                                         // fee recipient address
    mapping(uint256 => Listing) listings;                        // tokenId => Listing
    mapping(address => mapping(address => bool)) isOperatorFor;   // owner => operator => approved
    mapping(address => bool) allowedPaymentToken;                 // whitelisted payment tokens
    // TODO: should we add a mapping of user address to listings?
}

struct Offer {
    address creator;                   // offer creator
    uint256 minWeight;                // minimum acceptable veNFT weight
    uint256 maxWeight;                // maximum acceptable veNFT weight
    uint256 debtTolerance;            // max acceptable loan balance
    uint256 price;                     // offer price in paymentToken
    address paymentToken;              // whitelisted token
    uint256 maxLockTime;              // maximum acceptable lock time for veNFT
    uint256 expiresAt;                // 0 = never
    uint256 offerId;                  // unique offer identifier
}

struct Listing {
    address owner;                    // LoanV2.borrower
    uint256 tokenId;
    uint256 price;                    // in paymentToken decimals
    address paymentToken;             // whitelisted token
    bool hasOutstandingLoan;          // if true, buyer must also pay current loan balance
    uint256 expiresAt;                // 0 = never
}

// Immutable variables (set in constructor)
ILoan private immutable _loan;                           // LoanV2 contract reference
IVotingEscrow private immutable _votingEscrow;           // VotingEscrow contract reference
```

Storage notes:
- All Market state uses **ERC-7201 namespaced storage** for upgrade safety
- Listings are deleted (not marked inactive) when completed/cancelled
- Immutable contract references prevent accidental storage overwrites

---

## Events
```solidity
event ListingCreated(uint256 indexed tokenId, address indexed owner, uint256 price, address paymentToken, bool hasOutstandingLoan, uint256 expiresAt);
event ListingUpdated(uint256 indexed tokenId, uint256 price, address paymentToken, uint256 expiresAt);
event ListingCancelled(uint256 indexed tokenId);
event ListingTaken(uint256 indexed tokenId, address indexed buyer, uint256 price, uint256 fee);
event OfferCreated(uint256 indexed offerId, address indexed creator, uint256 minWeight, uint256 maxWeight, uint256 debtTolerance, uint256 price, address paymentToken, uint256 maxLockTime, uint256 expiresAt);
event OfferUpdated(uint256 indexed offerId, uint256 newMinWeight, uint256 newMaxWeight, uint256 newDebtTolerance, uint256 newPrice, address newPaymentToken, uint256 newMaxLockTime, uint256 newExpiresAt);
event OfferCancelled(uint256 indexed offerId);
event OfferAccepted(uint256 indexed offerId, uint256 indexed tokenId, address indexed seller, uint256 price, uint256 fee);
event OfferMatched(uint256 indexed offerId, uint256 indexed tokenId, address indexed buyer, uint256 price, uint256 fee);
event OperatorApproved(address indexed owner, address indexed operator, bool approved);
event PaymentTokenAllowed(address indexed token, bool allowed);
event MarketFeeChanged(uint16 newBps);
event FeeRecipientChanged(address newRecipient);
```

---

## External Functions

### Listing management
  * If veNFT is in caller's wallet ⇒ UI calls `LoanV2.requestLoan(tokenId, 0, 0, address(0), false, false)` to move custody. must happen before calling makeListing.
* **makeListing**(`uint256 tokenId, uint256 price, address paymentToken, uint256 expiresAt`)
  * Caller must be **borrower** of token OR approved operator.
  * Checks current loan balance to set `hasOutstandingLoan` flag.
  * Stores listing and emits `ListingCreated`.

* **updateListing**(`uint256 tokenId, uint256 newPrice, address newPaymentToken, uint256 newExpiresAt`)
* **cancelListing**(`uint256 tokenId`)

### Offer management
* **createOffer**(`uint256 minWeight, uint256 maxWeight, uint256 debtTolerance, uint256 price, address paymentToken, uint256 maxLockTime, uint256 expiresAt`)
  * Caller pays the full offer price upfront
  * Validates minWeight ≤ maxWeight and expiration > block.timestamp
  * Stores offer and emits `OfferCreated`.

* **updateOffer**(`uint256 offerId, uint256 newMinWeight, uint256 newMaxWeight, uint256 newDebtTolerance, uint256 newPrice, address newPaymentToken, uint256 newMaxLockTime, uint256 newExpiresAt`)
  * Offer creator can update active offers
  * Validates new parameters and expiration
  * Emits `OfferUpdated`

* **cancelOffer**(`uint256 offerId`)
  * Offer creator can cancel their own offers
  * Refunds the offer price to the creator
  * Emits `OfferCancelled`

### Offer acceptance and matching
* **acceptOffer**(`uint256 tokenId, uint256 offerId`)
  * Seller can accept a valid offer for their veNFT
  * Verifies veNFT weight/debt/lock time matches offer criteria
  * Seller receives the offer price (net of fees)
  * Emits `OfferAccepted`
  * Deletes the offer

* **matchOfferWithListing**(`uint256 offerId, uint256 tokenId`)
  * Matches an offer with an existing listing
  * Verifies veNFT weight/debt/lock time matches offer criteria
  * Buyer receives the veNFT, seller receives the offer price
  * Emits `OfferMatched`
  * Deletes both listing and offer

### Purchase paths
* **takeListing**(`uint256 tokenId`) – simple cases (no loan OR buyer pays full outstanding from wallet).

### Operator management
* **setOperatorApproval**(`address operator, bool approved`) – user function.

### View functions
* **getListing**(`uint256 tokenId`) → returns tuple: `(owner, price, paymentToken, hasOutstandingLoan, expiresAt)`
* **getTotalCost**(`uint256 tokenId`) → returns tuple: `(total, listingPrice, loanBalance, paymentToken)`
  * `total` = listing price + current loan balance (if hasOutstandingLoan)
  * `listingPrice` = just the listing price  
  * `loanBalance` = current balance from LoanV2 (if hasOutstandingLoan)
  * `paymentToken` = token needed for payment
* **isListingActive**(`uint256 tokenId`) → returns `true` if listing exists and `(expiresAt==0 || block.timestamp < expiresAt)`
* **canOperate**(`address veNFTowner, address operator`) → view operator status

### Public state getters
* **loan**() → address of LoanV2 contract
* **marketFeeBps**() → current market fee in basis points
* **feeRecipient**() → current fee recipient address
* **listings**(`uint256 tokenId`) → full Listing struct
* **isOperatorFor**(`address owner, address operator`) → operator approval status
* **allowedPaymentToken**(`address token`) → whether token is whitelisted

### Admin functions
* **setMarketFee**(`uint16 bps`) – ≤ 1000 (10% max).
* **setFeeRecipient**(`address recipient`)
* **setAllowedPaymentToken**(`address token, bool allowed`)
* **pause() / unpause()**

---

## Transaction Flows
### A. Listing Creation (`makeListing`)
1. Verify paymentToken is allowed; if `expiresAt!=0` ensure future timestamp.
2. Verify veNFT is already in `LoanV2` custody (user must call `LoanV2.requestLoan()` first via UI).
3. Check if token has loan balance in LoanV2, set hasOutstandingLoan accordingly.
4. Record Listing using `MarketStorage`, emit `ListingCreated`.

### B. Purchase – No Outstanding Loan
1. Get total cost via `getTotalCost` (just price in this case).
2. Buyer transfers `price` in `paymentToken`.
3. Compute `fee = price * marketFeeBps / 10000`.
4. Send fee to `feeRecipient`, remainder to seller.
5. `LoanV2.setBorrower(tokenId, buyer)`.
6. Delete listing from storage, emit `ListingTaken`.

### C. Purchase – Buyer Pays Outstanding Loan (`takeListing`)
1. Get total cost via `getTotalCost` (price + current loan balance).
2. Buyer transfers total amount.
3. Market calls `LoanV2.pay(tokenId, loanBalance)`.
4. Steps 3-6 of flow B (compute fee on price only).

### D. Offer Creation (`createOffer`)
1. Validate paymentToken is allowed
2. Ensure minWeight ≤ maxWeight and expiration > block.timestamp
3. Transfer full offer price from caller to contract
4. Create offer with auto-incrementing offerId
5. Store offer in offers mapping
6. Emit `OfferCreated` event

### E. Offer Acceptance (`acceptOffer`)
1. Verify seller owns the veNFT (in wallet or as borrower)
2. Verify veNFT weight/debt/lock time matches offer criteria
3. Compute fee = price * marketFeeBps / 10000
4. Transfer fee to feeRecipient, remainder to seller
5. If veNFT is in LoanV2, call `LoanV2.setBorrower(tokenId, offer.creator)` else
6. Delete the offer
7. Emit `OfferAccepted` event

### F. Offer Matching (`matchOfferWithListing`)
1. Verify listing exists and is active
2. Verify veNFT weight/debt/lock time matches offer criteria
3. Compute fee = price * marketFeeBps / 10000
4. Transfer fee to feeRecipient, remainder to listing owner
5. Call `LoanV2.setBorrower(tokenId, offer.creator)`
6. Delete both listing and offer
7. Emit `OfferMatched` event

## Security Considerations
* **Reentrancy**: all payable external functions are `nonReentrant`.
* **Pausability**: operator can pause during emergencies.
* **Fee cap**: prevents abusive configuration (10% maximum).
* **Payment token whitelist**: avoids griefing with malicious ERC-20s.
* **Offer validation**: ensures veNFT weight/debt matches offer criteria before acceptance
* **Offer creator control**: only offer creators can update/cancel offers
* **Upgrade safety**: ERC-7201 namespaced storage prevents storage collisions
* **Access control**: proper authorization checks for all operations.

---

## Storage Layout (ERC-7201)
// Storage namespace: "erc7201:storage:MarketStorage"

// Location: 0x9a18c57b4cb912563e1d8b7faab1ce6cccddad5bcd773a70cdfb7f991efa2200

## Offer Contract Specification

### Overview
The **Offer** contract allows users to create offers to purchase veNFTs that are used as collateral in the `LoanV2` lending system. Offers must be able to fulfill a listing or allow a seller to accept the offer. Offers are matched based on veNFT weight and debt parameters.

### State Variables
```solidity
// Stored in MarketStorage using ERC-7201 namespaced storage
struct Offer {
    address creator;                   // offer creator
    uint256 minWeight;                // minimum acceptable veNFT weight
    uint256 maxWeight;                // maximum acceptable veNFT weight
    uint256 debtTolerance;            // max acceptable loan balance
    uint256 price;                     // offer price in paymentToken
    address paymentToken;              // whitelisted token
    uint256 maxLockTime;              // maximum acceptable lock time for veNFT
    uint256 expiresAt;                // 0 = never
    uint256 offerId;                  // unique offer identifier
}

// Offer-specific state
uint256 private _offerCounter;        // auto-incrementing offer ID
```

### Weight and Debt Determination
The Market contract uses external functions from LoanV2 to validate veNFT parameters:

1. **Weight Calculation**:
   - If veNFT is in LoanV2: Uses `ILoan.getLoanWeight(tokenId)` to get the weight stored in LoanInfo
   - If veNFT is in wallet: Uses `IVotingEscrow.locked(tokenId).amount` to get the current locked amount
   - Weight must be ≥ `offer.minWeight` and ≤ `offer.maxWeight`
   - Weight validation follows LoanV2's `getMinimumLocked()` requirement

2. **Debt Calculation**:
   - Uses `ILoan.getLoanDetails(tokenId)` to get current loan balance
   - Debt must be ≤ `offer.debtTolerance`
   - Balance includes both principal and unpaid fees from LoanV2's state

3. **Lock Time Validation**:
   - Uses `IVotingEscrow.locked(tokenId)` to get veNFT's lock time
   - Lock time must be ≤ `offer.maxLockTime`
   - Ensures buyer gets veNFT with sufficient lock duration

4. **Validation**:
   - Offer creation requires `minWeight ≤ maxWeight`
   - Offer acceptance validates against current values from external contracts
   - All checks use read-only external calls to maintain contract isolation

Storage notes:
- Weight/debt values are validated through external contract calls
- Offers are deleted when accepted/cancelled to maintain storage efficiency
- Debt tolerance uses LoanV2's balance tracking mechanism

Storage notes:
- Offers use the same **ERC-7201 namespaced storage** as listings
- Offers are deleted when accepted/cancelled to maintain storage efficiency
- Offer IDs are sequential and managed by _offerCounter

### External Functions
* **createOffer**(`uint256 minWeight, uint256 maxWeight, uint256 debtTolerance, uint256 price, address paymentToken, uint256 maxLockTime, uint256 expiresAt`)
  * Caller pays the full offer price upfront
  * Validates minWeight ≤ maxWeight and expiration > block.timestamp
  * Stores offer with auto-incrementing offerId
  * Emits `OfferCreated`

* **updateOffer**(`uint256 offerId, uint256 newMinWeight, uint256 newMaxWeight, uint256 newDebtTolerance, uint256 newPrice, address newPaymentToken, uint256 newMaxLockTime, uint256 newExpiresAt`)
  * Offer creator can update active offers
  * Validates new parameters and expiration
  * Emits `OfferUpdated`

* **cancelOffer**(`uint256 offerId`)
  * Offer creator can cancel their own offers
  * Refunds the offer price to the creator
  * Emits `OfferCancelled`

* **acceptOffer**(`uint256 tokenId, uint256 offerId, bool isInLoanV2`)
  * Seller can accept a valid offer for their veNFT
  * `isInLoanV2` flag indicates whether veNFT is in LoanV2 (true) or wallet (false)
  * Verifies veNFT weight/debt/lock time matches offer criteria
  * Seller receives the offer price (net of fees)
  * Emits `OfferAccepted` and deletes the offer

* **matchOfferWithListing**(`uint256 offerId, uint256 tokenId`)
  * Matches an offer with an existing listing
  * Verifies veNFT weight/debt/lock time matches offer criteria
  * Buyer receives the veNFT, seller receives the offer price
  * Emits `OfferMatched` and deletes both listing and offer

### Transaction Flows
#### D. Offer Creation (`createOffer`)
1. Validate paymentToken is allowed
2. Ensure minWeight ≤ maxWeight and expiration > block.timestamp
3. Transfer full offer price from caller to contract
4. Create offer with auto-incrementing offerId
5. Store offer in offers mapping
6. Emit `OfferCreated` event

#### E. Offer Acceptance (`acceptOffer`)
1. Verify seller owns the veNFT (in wallet or as borrower)
2. Use `isInLoanV2` flag to determine weight calculation method
3. Verify veNFT weight/debt/lock time matches offer criteria
4. Compute fee = price * marketFeeBps / 10000
5. Transfer fee to feeRecipient, remainder to seller
6. If `isInLoanV2`: Call `LoanV2.setBorrower(tokenId, offer.creator)`
7. If not `isInLoanV2`: Transfer from wallet to offer creator
8. Delete the offer
9. Emit `OfferAccepted` event

#### F. Offer Matching (`matchOfferWithListing`)
1. Verify listing exists and is active
2. Verify veNFT weight/debt/lock time matches offer criteria
3. Compute fee = price * marketFeeBps / 10000
4. Transfer fee to feeRecipient, remainder to listing owner
5. Call `LoanV2.setBorrower(tokenId, offer.creator)`
6. Delete both listing and offer
7. Emit `OfferMatched` event

### Security Considerations
* **Offer validation**: Ensures veNFT weight/debt matches offer criteria before acceptance
* **Offer creator control**: Only offer creators can update/cancel their own offers
* **Reentrancy protection**: All payable functions use `nonReentrant` guard
* **Pausability**: Offer acceptance is blocked when market is paused
* **Payment token whitelist**: Prevents griefing with malicious ERC-20s
* **Upgrade safety**: Uses same ERC-7201 storage pattern as listings
* **Access control**: Reuses existing authorization checks from listings
* **Expiration enforcement**: Offers cannot be created with past expiration timestamps

### Event Emissions
```solidity
event OfferCreated(uint256 indexed offerId, address indexed creator, uint256 minWeight, uint256 maxWeight, uint256 debtTolerance, uint256 price, address paymentToken, uint256 maxLockTime, uint256 expiresAt);
event OfferUpdated(uint256 indexed offerId, uint256 newMinWeight, uint256 newMaxWeight, uint256 newDebtTolerance, uint256 newPrice, address newPaymentToken, uint256 newMaxLockTime, uint256 newExpiresAt);
event OfferCancelled(uint256 indexed offerId);
event OfferAccepted(uint256 indexed offerId, uint256 indexed tokenId, address indexed seller, uint256 price, uint256 fee);
event OfferMatched(uint256 indexed offerId, uint256 indexed tokenId, address indexed buyer, uint256 price, uint256 fee);
```


### State Variables
```solidity
// Stored in MarketStorage using ERC-7201 namespaced storage
struct Offer {
    address creator;                   // offer creator
    uint256 minWeight;                // minimum acceptable veNFT weight
    uint256 maxWeight;                // maximum acceptable veNFT weight
    uint256 debtTolerance;            // max acceptable loan balance
    uint256 price;                     // offer price in paymentToken
    address paymentToken;              // whitelisted token
    uint256 expiresAt;                // 0 = never
    uint256 offerId;                  // unique offer identifier
}

// Offer-specific state
uint256 private _offerCounter;        // auto-incrementing offer ID
```
