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
- Market facets
  - `src/facets/market/MarketConfigFacet.sol` (implements `IMarketConfigFacet`): admin and initialization for Market.
  - `src/facets/market/MarketViewFacet.sol` (implements `IMarketViewFacet`): read‑only views.
  - `src/facets/market/MarketOperationsFacet.sol` (implements `IMarketOperationsFacet`): listings/offers operations.
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

### Public surface (selected)

- Market view (via `IMarketViewFacet`)
  - `loan()`, `marketFeeBps()`, `feeRecipient()`
  - `allowedPaymentToken(token)`, `isOperatorFor(owner, operator)`
  - `getListing(tokenId)`, `getOffer(offerId)`
  - `getTotalCost(tokenId)`
  - `isListingActive(tokenId)`, `isOfferActive(offerId)`, `canOperate(owner, operator)`

- Market operations (via `IMarketOperationsFacet`)
  - Listings: `makeListing`, `updateListing`, `cancelListing`, `takeListing`
  - Offers: `createOffer`, `updateOffer`, `cancelOffer`, `acceptOffer`, `matchOfferWithListing`
  - Operators: `setOperatorApproval(operator, approved)`

- Market admin (via `IMarketConfigFacet`)
  - `setMarketFee(bps)`, `setFeeRecipient(addr)`, `setAllowedPaymentToken(token, allowed)`
  - `pause()`, `unpause()`

Notes:
- All mutating ops are protected by `nonReentrant` (storage-based guard) and `marketPaused`.
- Token transfers use OpenZeppelin `SafeERC20` directly (no LibTransfer). Fee‑on‑transfer tokens are supported via balance deltas where needed.

### Events
- From `IMarketOperationsFacet` (emitted by ops facet):
  - `ListingCreated`, `ListingUpdated`, `ListingCancelled`, `ListingTaken`
  - `OfferCreated`, `OfferUpdated`, `OfferCancelled`, `OfferAccepted`, `OfferMatched`
  - `OperatorApproved`
- From `IMarketConfigFacet` (emitted by config facet):
  - `MarketInitialized`, `PaymentTokenAllowed`, `MarketFeeChanged`, `FeeRecipientChanged`, `MarketPauseStatusChanged`

### Upgrades (diamond cuts)
- Use `DiamondCutFacet.diamondCut(FacetCut[], _init, _calldata)` to add/replace/remove function selectors.
- Typical workflow:
  1. Deploy new facet.
  2. Build `FacetCut[]` with action Add/Replace and list of selectors.
  3. Optionally pass `_init` and `_calldata` to run an initialization call in the same transaction.

Example: replace a function in `MarketOperationsFacet` and run no initializer
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

### Design choices
- Types are defined next to their storage to ensure shape fidelity and easier refactors.
- Events are defined on interfaces and emitted by facets to keep ABI consistent.


