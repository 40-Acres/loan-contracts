# Diamond Market implementation README

## Goals for the market functionality
- Buy and sell veNFTs in a 40Acre LoanV2 contract
  - requires the veNFT to be in the 40Acre LoanV2 contract
- Buy and sell veNFTs not in a 40Acre on network's where the LoanV2 contract is not deployed
  - requires listings and offers on veNFTs (not in the 40Acre LoanV2 contract) in user wallet and we need admin functions to remove ones that are invalid because they removed approvals
- Buy veNFT from another market (aggregate veNFT markets into ours)
  - new facet for each external market

## Diamond architecture (EIP-2535)

This repo implements a modular diamond for the Market domain following EIP-2535. The diamond aggregates multiple facets behind a single proxy address, enabling fine‑grained upgrades and clear separation of concerns.

### Key contracts
- Core facets
  - `src/facets/core/DiamondCutFacet.sol`: adds/replaces/removes function selectors on the diamond.
  - `src/facets/core/DiamondLoupeFacet.sol`: standard loupe view functions for tooling and discovery.
  - `src/facets/core/OwnershipFacet.sol`: IERC173-compatible ownership with 2‑step handover (Ownable2Step semantics).
- Market facets (current split)
  - `src/facets/market/MarketConfigFacet.sol` (implements `IMarketConfigFacet`): admin and initialization for Market. Supports optional LoanV2 and `loanAsset` configuration.
  - `src/facets/market/MarketViewFacet.sol` (implements `IMarketViewFacet`): read‑only views.
  - `src/facets/market/MarketListingsLoanFacet.sol` (implements `IMarketListingsLoanFacet`): listings and takes for veNFTs in LoanV2 custody, including debt‑tolerant take.
  - `src/facets/market/MarketListingsWalletFacet.sol` (implements `IMarketListingsWalletFacet`): listings and takes for wallet‑held veNFTs (no LoanV2 custody).
  - `src/facets/market/MarketOfferFacet.sol` (implements `IMarketOfferFacet`): offer lifecycle and accept.
  - `src/facets/market/MarketMatchingFacet.sol` (implements `IMarketMatchingFacet`): match offers with loan or wallet listings.
  - `src/facets/market/MarketOperatorFacet.sol` (implements `IMarketOperatorFacet`): operator approvals per account.
- Diamond entry
  - `src/diamonds/DiamondHitch.sol`: the diamond root contract that delegates to facets using LibDiamond.

### Storage layout (ERC‑7201)
Market state is isolated in `src/libraries/storage/MarketStorage.sol`:

- MarketConfigLayout (slot: `market.config.storage`)
  - `uint16 marketFeeBps`
  - `address feeRecipient`
  - `mapping(address => bool) allowedPaymentToken`
  - `address loan`
  - `address votingEscrow`
  - `address accessManager`
  - `address loanAsset` (expected asset for `LoanV2.pay()`, e.g., USDC)

- MarketPauseLayout (slot: `market.pause.storage`)
  - `bool marketPaused`
  - `uint256 reentrancyStatus` (1 = NOT_ENTERED, 2 = ENTERED)

- MarketOrderbookLayout (slot: `market.orderbook.storage`)
  - `mapping(address => mapping(address => bool)) isOperatorFor`
  - `mapping(uint256 => Listing) listings`
  - `mapping(uint256 => Offer) offers`
  - `uint256 _offerCounter`

- Types defined alongside storage
  - `struct Listing { address owner; uint256 tokenId; uint256 price; address paymentToken; bool hasOutstandingLoan; uint256 expiresAt; }`
  - `struct Offer { address creator; uint256 minWeight; uint256 maxWeight; uint256 debtTolerance; uint256 price; address paymentToken; uint256 maxLockTime; uint256 expiresAt; uint256 offerId; }`

This co‑location ensures types match storage shape and avoids cross‑interface type coupling.

### Current facet split
To support multi‑chain deployments, market aggregation, and clearer upgrade boundaries, responsibilities are split while sharing a single orderbook and config storage.

- Core/admin/views (keep):
  - `MarketConfigFacet` (admin, init, `setLoanAsset`, allowlists, pause)
  - `MarketViewFacet` (views: `loan()`, `loanAsset()`, `marketFeeBps()`, `getListing()`, `getOffer()`, etc.)

- Order creation (separate facets per asset mode):
  - `MarketListingsLoanFacet`
    - `makeLoanListing`, `updateLoanListing`, `cancelLoanListing`
    - `takeLoanListing` (full payoff) and `takeLoanListingWithDebt(debtTolerance)` for buyer‑tolerant residual debt
    - Enforces `listing.paymentToken == loanAsset` for payoff. A swap adapter can be introduced later if `LoanV2.pay()` requires a specific asset.
  - `MarketListingsWalletFacet`
    - `makeWalletListing`, `updateWalletListing`, `cancelWalletListing`
    - `takeWalletListing` (direct `votingEscrow.transferFrom` path)

- Offers and matching:
  - `MarketOfferFacet`
    - `createOffer`, `updateOffer`, `cancelOffer`, `acceptOffer(tokenId, offerId, isInLoanV2)`
  - `MarketMatchingFacet`
    - `matchOfferWithLoanListing`, `matchOfferWithWalletListing`
    - Future: `matchExternal{Market}` variants (see adapters below)

- Operators:
  - `MarketOperatorFacet`
    - `setOperatorApproval(operator, approved)`

- Adapter facets (future, optional):
  - External market adapters (e.g., `ExternalMarketAdapterFacet`, `ExternalXAdapterFacet`): quote/take/accept against external orderbooks.
  - `SwapAdapterFacet`: best‑effort swaps from buyer’s payment token to `loanAsset` during loan settlement.
  - `BridgeAdapterFacet`: escrow/intents for cross‑chain settlement.

Example external adapter implemented:
- `VexyAdapterFacet` (interface `IVexyAdapterFacet`)
  - `buyVexyListing(marketplace, listingId, expectedCurrency, maxPrice)`:
    - Verifies Vexy listing state and endTime, checks our `allowedPaymentToken`, enforces currency match and maxPrice.
    - Pulls funds from buyer, approves the Vexy marketplace, executes `buyListing`, and forwards the acquired NFT to the buyer.
  - Events: `VexyListingPurchased`.

All of the above read/write the same `MarketStorage` mappings: a single shared orderbook (`listings`, `offers`, `isOperatorFor`) and config/pause storage.

Notes on naming: explicit function names improve clarity where different asset modes exist. Examples: `makeLoanListing`, `takeLoanListingWithDebt`, `matchOfferWithWalletListing`.

### Code sharing: prefer libraries over base facet inheritance
Facets are units of upgrade and replacement. Inheriting from a shared "base facet" couples unrelated selectors together, increases facet bytecode size, and makes method-resolution-order and storage access harder to reason about during upgrades. Instead:

- Put shared, side‑effect‑free helpers in small internal libraries (e.g., `MarketLogicLib`) that operate on `MarketStorage` layouts.
- Keep facets thin and focused on orchestrating flows and emitting events.
- Override behavior by swapping the facet, not by overriding inherited virtuals spread across multiple selectors.

Benefits:
- Lower coupling between facets; safer, targeted upgrades.
- Smaller facet code size; easier audits.
- Clearer boundaries (each facet composes logic via libraries rather than inherits it).

### Ownership and access control
- Ownership (two‑step): `OwnershipFacet`
  - `transferOwnership(newOwner)`: owner can stage a transfer. Passing `address(0)` cancels any pending transfer.
  - `acceptOwnership()`: pending owner accepts.
  - `renounceOwnership()`: owner sets owner to `address(0)` and clears pending transfer.

- Role‑based admin (optional, via OZ AccessManager)
  - `MarketConfigFacet` supports `initAccessManager(address)` and `setAccessManager(address)`.
  - A role id of `MARKET_ADMIN` (uint64 = 1) is checked via `IAccessManager.hasRole(roleId, account)`.
  - All admin functions (fee updates, pause, token allowlist) are gated by Owner OR MARKET_ADMIN.
  - You can further bind selectors to roles using `IAccessManager.setTargetFunctionRole(diamond, selectors, roleId)`.

### Initialization flow
Call these once (via a diamond cut initializer or a post‑deployment transaction):

1) Configure AccessManager (optional)
```solidity
IMarketConfigFacet(diamond).initAccessManager(accessManager);
```

2) Initialize Market
```solidity
IMarketConfigFacet(diamond).initMarket({
  loan: loanAddress,
  votingEscrow: veAddress,
  marketFeeBps: 50, // 0.5%
  feeRecipient: treasury,
  defaultPaymentToken: usdc
});
```

Optional: set the expected `loanAsset` for loan settlement (e.g., USDC) if different from the default payment token.
```solidity
IMarketConfigFacet(diamond).setLoanAsset(usdc);
```

### Public surface (selected)

- Market view (via `IMarketViewFacet`)
  - `loan()`, `marketFeeBps()`, `feeRecipient()`, `loanAsset()`
  - `allowedPaymentToken(token)`, `isOperatorFor(owner, operator)`
  - `getListing(tokenId)`, `getOffer(offerId)`
  - `getTotalCost(tokenId)`
  - `isListingActive(tokenId)`, `isOfferActive(offerId)`, `canOperate(owner, operator)`

- Loan listings (via `IMarketListingsLoanFacet`)
  - `makeLoanListing`, `updateLoanListing`, `cancelLoanListing`
  - `takeLoanListing`, `takeLoanListingWithDebt(tokenId, debtTolerance)`

- Wallet listings (via `IMarketListingsWalletFacet`)
  - `makeWalletListing`, `updateWalletListing`, `cancelWalletListing`
  - `takeWalletListing`

- Offers (via `IMarketOfferFacet`)
  - `createOffer`, `updateOffer`, `cancelOffer`, `acceptOffer(tokenId, offerId, isInLoanV2)`

- Matching (via `IMarketMatchingFacet`)
  - `matchOfferWithLoanListing`, `matchOfferWithWalletListing`

- Operators (via `IMarketOperatorFacet`)
  - `setOperatorApproval(operator, approved)`

- Market admin (via `IMarketConfigFacet`)
  - `setMarketFee(bps)`, `setFeeRecipient(addr)`, `setAllowedPaymentToken(token, allowed)`
  - `pause()`, `unpause()`

Notes:
- All mutating ops are protected by `nonReentrant` (storage-based guard) and `marketPaused`.
- Token transfers use OpenZeppelin `SafeERC20` directly (no LibTransfer). Fee‑on‑transfer tokens are supported via balance deltas where needed.

### Events
- From listing facets (`IMarketListingsLoanFacet`, `IMarketListingsWalletFacet`):
  - `ListingCreated`, `ListingUpdated`, `ListingCancelled`, `ListingTaken`
- From offers (`IMarketOfferFacet`):
  - `OfferCreated`, `OfferUpdated`, `OfferCancelled`, `OfferAccepted`
- From matching (`IMarketMatchingFacet`):
  - `OfferMatched`
- From operators (`IMarketOperatorFacet`):
  - `OperatorApproved`
- From config (`IMarketConfigFacet`):
  - `MarketInitialized`, `PaymentTokenAllowed`, `MarketFeeChanged`, `FeeRecipientChanged`, `MarketPauseStatusChanged`

### Upgrades (diamond cuts)
- Use `DiamondCutFacet.diamondCut(FacetCut[], _init, _calldata)` to add/replace/remove function selectors.
- Typical workflow:
  1. Deploy new facet.
  2. Build `FacetCut[]` with action Add/Replace and list of selectors.
  3. Optionally pass `_init` and `_calldata` to run an initialization call in the same transaction.

Example: replace a function in `MarketOfferFacet` and run no initializer
```solidity
IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
cut[0] = IDiamondCut.FacetCut({
  facetAddress: address(newFacet),
  action: IDiamondCut.FacetCutAction.Replace,
  functionSelectors: selectorsArray
});
IDiamondCut(diamond).diamondCut(cut, address(0), bytes("");
```

### Deployment tips
- Deploy the diamond root (e.g., `DiamondHitch`), core facets, then market facets.
- Perform an Add cut for each facet with the desired selectors.
- Initialize AccessManager (optional) and `initMarket` via a final cut or direct calls.

### Testing
- Unit test facets directly using Foundry by calling through the diamond address.
- Verify pause and reentrancy guard behaviors in concurrent calls.
- Exercise all flows: listing lifecycle, offer lifecycle, match paths, fee distribution.

### Security considerations
- Reentrancy guard is storage‑based; all state‑changing functions in ops facet are `nonReentrant`.
- Pausable guard for ops to halt the market during incidents.
- Two‑step ownership reduces risk of accidental ownership loss.
- AccessManager integration allows delegation to a system admin role without giving away full ownership.

Payment asset safety:
- For loan listings, settlement calls `LoanV2.pay()`. Until a swap adapter is added, the market enforces that `listing.paymentToken == loanAsset` to avoid asset mismatch.

### Design choices
- Types are defined next to their storage to ensure shape fidelity and easier refactors.
- Events are defined on interfaces and emitted by facets to keep ABI consistent.

### Extensibility roadmap
- External market aggregation
  - Add adapter facets per external protocol. The `MarketMatchingFacet` routes matches between our orderbook and external orders.
- Cross‑chain support
  - Introduce a bridge adapter to escrow funds and emit settlement intents. A relayer finalizes on the destination chain.
- Richer matching and quotes
  - Add additional quote/preview views (e.g., `quoteTakeLoanListingWithDebt`) for better frontend UX and off‑chain matchers.
- Feature gating per chain
  - Omit facets that are not applicable (e.g., loan listings where LoanV2 isn’t deployed), keeping a single diamond address with a consistent view surface.


