# Market Contract Specification

## Overview
The **Market** contract allows users to list and purchase **veNFTs** that are used as collateral in the `LoanV2` lending system.  Purchases can occur when the veNFT has:
1. **No outstanding loan**
2. **Outstanding loan paid by the buyer** (from wallet)
3. **Outstanding loan paid via flash-loan** (`borrowAndTake`) where part or all of the payoff is borrowed against the veNFT itself in a single atomic transaction.

All veNFT custody remains inside `LoanV2`; the Market only orchestrates loan settlement, ownership transfer, price settlement, and fee collection.

The contract is **upgradeable (UUPS)**, **pausable**, and protected by **ReentrancyGuard**.

---

## Contract Architecture

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

struct Listing {
    address owner;                    // LoanV2.borrower
    uint256 tokenId;
    uint256 price;                    // in paymentToken decimals
    address paymentToken;             // whitelisted token
    bool hasOutstandingLoan;          // if true, buyer must also pay current loan balance
    uint256 expiresAt;                // 0 = never
}

// Immutable variables (set in constructor)
ILoanV2 private immutable _loan;                         // LoanV2 contract reference
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
event OperatorApproved(address indexed owner, address indexed operator, bool approved);
event PaymentTokenAllowed(address indexed token, bool allowed);
event MarketFeeChanged(uint16 newBps);
event FeeRecipientChanged(address newRecipient);
```

---

## External Functions

### Listing management
* **makeListing**(`uint256 tokenId, uint256 price, address paymentToken, uint256 expiresAt, LoanV2.ZeroBalanceOption zbo`)
  * Caller must be **borrower** of token OR approved operator.
  * If veNFT is in caller's wallet ⇒ Market calls `LoanV2.requestLoan(tokenId, 0, zbo, 0, address(0), false, false)` to move custody.
  * Checks current loan balance to set `hasOutstandingLoan` flag.
  * Stores listing and emits `ListingCreated`.

* **updateListing**(`uint256 tokenId, uint256 newPrice, address newPaymentToken, uint256 newExpiresAt`)
* **cancelListing**(`uint256 tokenId`)

### Purchase paths
* **takeListing**(`uint256 tokenId`) – simple cases (no loan OR buyer pays full outstanding from wallet).
* **borrowAndTake**(`uint256 tokenId, uint256 payoffFromBuyer, bool useFlashLoan`) – advanced path allowing partial wallet payoff and optional flash-loan.

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
2. If veNFT **not** yet in `LoanV2` custody ⇒
   * Market calls `LoanV2.requestLoan(tokenId, 0, zbo, 0, address(0), false, false)` to move custody.
3. Check if token has loan balance in LoanV2, set hasOutstandingLoan accordingly.
4. Record Listing using `MarketStorage`, emit `ListingCreated`.

### B. Purchase – No Outstanding Loan
1. Get total cost via `getTotalCost` (just price in this case).
2. Buyer transfers `price` in `paymentToken`.
3. Compute `fee = price * marketFeeBps / 10000`.
4. Send fee to `feeRecipient`, remainder to seller.
5. `LoanV2.transferLoanOwnership(tokenId, buyer)`.
6. Delete listing from storage, emit `ListingTaken`.

### C. Purchase – Buyer Pays Outstanding Loan (`takeListing`)
1. Get total cost via `getTotalCost` (price + current loan balance).
2. Buyer transfers total amount.
3. Market calls `LoanV2.pay(tokenId, loanBalance)`.
4. Steps 3-6 of flow B (compute fee on price only).

### D. Purchase – Flash-Loan Assisted (`borrowAndTake`)
Inputs: `payoffFromBuyer`, `useFlashLoan`.
1. Get total cost breakdown via `getTotalCost`.
2. `flashAmount = loanBalance - payoffFromBuyer` (0 if not using flashLoan).
3. Pull `payoffFromBuyer + listingPrice` from buyer wallet.
4. If `flashAmount>0` ⇒ invoke `LoanV2.flashLoan` (Market = receiver).
5. Inside `onFlashLoan`:
   1. Pay loan in full using wallet funds + flash.
   2. Transfer ownership to buyer.
   3. If `flashAmount>0` ⇒ immediately call `LoanV2.increaseLoan(tokenId, flashAmount)` on behalf of buyer (**LoanV2 upgrade must whitelist Market**).
   4. Repay flash loan + fee.
6. Settle listing price / fee as in flow B (delete listing).

Gas: `borrowAndTake` is single-transaction, amortising storage updates.

---

## Flash Loan Integration

Market implements `IFlashLoanReceiver` to handle complex purchase flows:

```solidity
function onFlashLoan(
    address initiator,
    address token,
    uint256 amount,
    uint256 fee,
    bytes calldata data
) external override returns (bytes32)
```

**Security checks:**
- Only callable by LoanV2 contract
- Only when Market is the initiator
- Returns `CALLBACK_SUCCESS` constant

**Flow inside callback:**
1. Decode purchase parameters from data
2. Pay off loan using flash funds + buyer wallet funds
3. Transfer veNFT ownership to buyer
4. Re-borrow flash amount for buyer (creating new loan)
5. Distribute listing price to seller (minus market fee)
6. Approve flash loan repayment

---

## Security Considerations
* **Reentrancy**: all payable external functions are `nonReentrant`.
* **Pausability**: operator can pause during emergencies.
* **Fee cap**: prevents abusive configuration (10% maximum).
* **Payment token whitelist**: avoids griefing with malicious ERC-20s.
* **Upgrade safety**: ERC-7201 namespaced storage prevents storage collisions.
* **Access control**: proper authorization checks for all operations.

---

## Storage Layout (ERC-7201)

```solidity
// Storage namespace: "erc7201:storage:MarketStorage"
// Location: 0x9a18c57b4cb912563e1d8b7faab1ce6cccddad5bcd773a70cdfb7f991efa2200
```

This ensures that Market storage is completely isolated from inherited contracts and future upgrades cannot accidentally overwrite state.

---

## Future Roadmap (non-blocking)
* Off-chain signature listings (EIP-712) to remove `setOperatorApproval` gas cost.
* Batch listing / batch take operations.
* Integration with meta-transactions.
* Cross-chain listing support.

---

## Revision History
* _v0.3 – 2025-01-30_: Updated to reflect final implementation with MarketStorage pattern and all view functions.
* _v0.2 – 2025-01-29_: Initial detailed specification replacing previous stub.