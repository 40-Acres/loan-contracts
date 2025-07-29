# Market Contract Specification

## Overview
The **Market** contract allows users to list and purchase **veNFTs** that are used as collateral in the `LoanV2` lending system.  Purchases can occur when the veNFT has:
1. **No outstanding loan**
2. **Outstanding loan paid by the buyer** (from wallet)
3. **Outstanding loan paid via flash-loan** (`BorrowAndTake`) where part or all of the payoff is borrowed against the veNFT itself in a single atomic transaction.

All veNFT custody remains inside `LoanV2`; the Market only orchestrates loan settlement, ownership transfer, price settlement, and fee collection.

The contract is **upgradeable (UUPS)**, **pausable**, and protected by **ReentrancyGuard**.

---

## Roles & Permissions
| Role | Abilities |
|------|-----------|
| **Owner** (`Ownable2StepUpgradeable`) | • pause/unpause<br/>• set `marketFeeBps` & `feeRecipient`<br/>• manage allowed payment tokens<br/>• approve/unapprove operator addresses globally |
| **Seller (listing owner)** | create / update / cancel their own listings |
| **Approved Operator** | on-chain operator authorised by seller via `setOperatorApproval` (similar to ERC-721 `setApprovalForAll`) that can update/cancel that specific listing |
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
uint16  public marketFeeBps;          // fee in basis points, max 1000 (10%)
address public feeRecipient;          // defaults to owner()

struct Listing {
    address owner;                    // LoanV2.borrower
    uint256 tokenId;
    uint256 price;                    // in paymentToken decimals
    address paymentToken;             // whitelisted token
    bool hasOutstandingLoan;          // if true, buyer must also pay current loan balance
    uint256 expiresAt;                // 0 = never
}

mapping(uint256 => Listing) public listings;           // tokenId => Listing
mapping(address => mapping(address => bool)) public isOperatorFor; // owner => operator => approved
mapping(address => bool) public allowedPaymentToken;   // default true for USDC
LoanV2 public immutable loan;                         // injected in initializer
```

Storage notes:
- Listings are deleted (not marked inactive) when completed/cancelled
- Simple unpacked storage for better maintainability and upgrades

---

## Events
```solidity
event ListingCreated(uint256 indexed tokenId, address indexed owner, uint256 price, address paymentToken, uint256 outstandingLoanBalance, uint256 expiresAt);
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
  * If veNFT is in caller’s wallet ⇒ Market calls `LoanV2.requestLoan(tokenId, 0, zbo, 0, address(0), false, false)` to move custody.
  * Stores listing with `active=true`.

* **updateListing**(`uint256 tokenId, uint256 newPrice, address newPaymentToken, uint256 newExpiresAt`)
* **cancelListing**(`uint256 tokenId`)

### Purchase paths
* **takeListing**(`uint256 tokenId`) – simple cases (no loan OR buyer pays full outstanding from wallet).
* **BorrowAndTake**(`uint256 tokenId, uint256 payoffFromBuyer, bool useFlashLoan`) – advanced path allowing partial wallet payoff and optional flash-loan.

### Admin
* **setMarketFee**(`uint16 bps`) – ≤ 1000.
* **setFeeRecipient**(`address recipient`)
* **setAllowedPaymentToken**(`address token, bool allowed`)
* **pause / unpause**

### User Admin functions
* **setOperatorApproval**(`address operator, bool approved`) – user function.

### View helpers
* **getListing**(`uint256 tokenId`) → `Listing` fields.
* **getTotalCost**(`uint256 tokenId`) → returns:
  * `total` = listing price + current loan balance (if hasOutstandingLoan)
  * `listingPrice` = just the listing price
  * `loanBalance` = current balance from LoanV2 (if hasOutstandingLoan)
  * `paymentToken` = token needed for payment
* **isListingActive**(`uint256 tokenId`) – returns `true` if listing exists and `(expiresAt==0 || block.timestamp < expiresAt)`.
* **canOperate**(`address veNFTowner, address operator`) – view operator status.

---

## Transaction Flows
### A. Listing Creation (`makeListing`)
1. Verify paymentToken is allowed; if `expiresAt!=0` ensure future timestamp.
2. If veNFT **not** yet in `LoanV2` custody ⇒
   * Market calls `LoanV2.requestLoan(tokenId, 0, zbo, 0, address(0), false, false)` to move custody.
3. Check if token has loan balance in LoanV2, set hasOutstandingLoan accordingly.
4. Record Listing, emit `ListingCreated`.

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

### D. Purchase – Flash-Loan Assisted (`BorrowAndTake`)
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

Gas: `BorrowAndTake` is single-transaction, amortising storage updates.

---

## Security Considerations
* Reentrancy: all payable external functions are `nonReentrant`.
* Pausability: operator can pause during emergencies.
* Fee cap prevents abusive configuration.
* Only whitelisted payment tokens accepted to avoid griefing with malicious ERC-20s.

---

## Future Roadmap (non-blocking)
* Off-chain signature listings (EIP-712) to remove `setOperatorApproval` gas cost.
* Batch listing / batch take.
* Integration with meta-transactions.

---

## Revision History
* _v0.2 – 2025-07-29_: initial detailed specification replacing previous stub.