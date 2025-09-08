## Diamond Market: lean, secure, and extensible

### Mission
Be the simplest way to buy and sell veNFTs across chains and markets, with optional leveraged buyout (LBO). Start by interoperating with existing `LoanV2`, then introduce an internal LoanV3 inside this diamond.

### Phases
- Phase A (now): Diamond market works with or without `LoanV2` on a chain. Wallet listings, LoanV2 listings (full payoff before transfer), external adapters (Vexy).
- Phase B: Add LBO checkout. Minimal, whitelisted `LoanV2` hooks; no‑origination for LBO; fee policy enforced by the diamond.
- Phase C: Launch LoanV3 facets inside this diamond. Support migration from LoanV2; unified listings/offers for both custody modes.

---

## Architecture (EIP‑2535)

Facets are thin orchestrators. Cross‑cutting safety and settlement live in internal libraries. Storage uses ERC‑7201 layouts in `src/libraries/storage/MarketStorage.sol`.

Core facets: `DiamondCutFacet`, `DiamondLoupeFacet`, `OwnershipFacet`.

Market facets:
- `MarketConfigFacet` (init/admin/pause/allowlists; expected `loanAsset`)
- `MarketViewFacet` (readonly)
- `MarketListingsWalletFacet` (wallet‑held listings/takes)
- `MarketListingsLoanFacet` (LoanV2/LoanV3‑held listings/takes; enforces payoff before transfer)
- `MarketOfferFacet` (offers)
- `MarketMatchingFacet` (single entry; routes to wallet/loan/external flows)
- Adapter facets (per external market). Example implemented: `src/facets/market/VexyAdapterFacet.sol`.

---

## Internal libraries

- MarketLogicLib
  - Listing/offer liveness checks; custody/owner resolution; operator rights.

- Permit2Lib
  - Optional Uniswap Permit2 permit+pull for exact‑input flows.
  - Optimization: if a sufficient, unexpired Permit2 allowance already exists, permit is skipped and only transferFrom is used.

- FeeLib
  - Protocol and adapter fee computations and recipients.

- RevertHelper
  - Bubble up revert data from delegatecalls to adapters and external markets.

- AccessRoleLib (+ AccessManager)
  - Owner and optional MARKET_ADMIN role gates for config/fees/pausing.

---

## Core invariants

- If a veNFT is in loan custody (LoanV2/LoanV3), outstanding debt must be fully paid before any transfer away from the custodian.
- All flows follow CEI, are nonReentrant, and perform external calls last.
- Payoff asset must equal `loanAsset()` unless a swap is executed with explicit slippage bounds.
- Infinite approvals granted only when necessary and zeroed immediately after use.

---

## Quoting and buying API (enum‑driven)

We define an enum route type and a registry of external markets per chain.

- Route enum (`RouteLib.BuyRoute`): `InternalWallet`, `InternalLoan`, `ExternalAdapter`.
- External market adapters are identified by `bytes32` keys (e.g., `VEXY`, `OPENX`, `SALVOR`) resolved to adapter addresses in config.
- Single‑veNFT per diamond: each deployment binds to one `votingEscrow`. All token IDs refer to this veNFT. For a new veNFT market/lending, deploy a new diamond. This simplifies routing and reduces attack surface.

Router rules (V1):
- ETH input requires `tradeData` (no direct‑ETH listings); if `inputAsset != address(0)`, `msg.value` must be zero.
- Exact‑output swaps only; the router/facets never refund leftovers.
- Post‑swap balances must cover settlement; otherwise revert (`Slippage`).
- InternalLoan route is gated: if `loan == address(0)`, router reverts `LoanNotConfigured`.

### RFQ off‑chain orders and Permit2
- EIP‑712 typed orders (Ask/Bid) signed off‑chain: include route, adapterKey, votingEscrow, tokenId, maker, optional taker, currency, price, expiry, nonce/salt, and `dataHash = keccak256(abi.encode(inputAsset, maxPaymentTotal, maxInputAmount, tradeData, marketData))`.
- On‑chain fill (`takeOrder`) verifies signature, nonce (replay‑protection), expiry, and data hash equality, then calls `buyToken` with the same (route, adapterKey, votingEscrow, tokenId, inputAsset, maxPaymentTotal, maxInputAmount, tradeData, marketData, optionalPermit2).
- Makers can cancel via nonce bump or explicit cancel. Permit2 is supported in `buyToken/takeOrder` to pull exact funds without prior ERC20 approvals. If a sufficient, unexpired Permit2 allowance already exists, the system skips the permit call and only transfers.

### LBO UX and indexing for external venues
- UI calls `quoteToken` with `ExternalAdapter` and `abi.encode(listingId, expectedCurrency, maxPrice)` and displays: price, fees, total, projected loan principal, financed LBO fee portion, and max LTV.
- Required indexed fields per listing: `(votingEscrow, tokenId)`, `adapterKey`, `listingId`, `expectedCurrency`, current price, endTime/sold flag. Loan inputs for preview: `loanAsset`, LTV caps, LBO fee config.
- `buyToken` with LBO flag performs: adapter buy to diamond custody → custody assert → lock into loan → open loan sized to LTV + financed fee → settle seller and fees → assign borrower.

---

- Leveraged Buyout (LBO)
  - Buyer acquires a veNFT and simultaneously opens a loan to finance it.
  - Fees: 2% LBO fee (buyer), 1% seller fee; no origination for the LBO loan.
  - Financing model: a portion of the LBO fee (default 1%) is financed (added to principal) and the remaining 1% is charged explicitly at checkout. Enforcement ensures total borrowed (purchase principal + financed fee) never exceeds the configured LTV cap.
  - Wallet/external source: diamond temporarily escrows the NFT, locks into loan custodian, opens loan for buyer with principal sized to (maxLtvBps − financedFeeBps), adds financed fee on top (financedFeeBps), directs proceeds to settle purchase, then assigns borrower.
  - LoanV2 listing source: pay off existing debt, assign borrower, optionally open a new loan immediately under the LBO rules.

### External LBO (adapter purchase financed by new loan)
- Atomicity: executed as a single transaction. If any sub‑step fails, the entire transaction reverts (including the external market purchase), ensuring funds and state roll back.
- Steps:
  1) Pre‑validate external listing (seller, venue votingEscrow, tokenId, currency, dynamic price) and cap price via maxPrice.
  2) Collect buyer funds (if any downpayment) and, if needed, draw a temporary credit from our vault (bounded by per‑tx/per‑user limits).
  3) Execute adapter buy; require NFT custody transfers to the diamond; verify via `ownerOf` post‑condition.
  4) Immediately lock NFT into loan custody and open loan for buyer. Compute principal and financed fee so that (principal + financed fee) ≤ max LTV.
  5) Route loan proceeds to repay the temporary credit; settle explicit fee and external aggregation fee; assign borrower.
- Guardrails:
  - Allowed marketplaces and currencies only; price/time bounds and balance‑delta checks; approvals zeroed post‑swap.
  - Vault credit caps (per‑tx, daily, and global), min buyer downpayment (configurable), and a kill‑switch to pause external LBO.
  - Post‑purchase assertion that custody is with the diamond before loan operations; otherwise revert.
- Availability: external LBO is enabled on chains where a loan custodian (LoanV2 or future LoanV3) and a funding vault are configured; otherwise disabled.

---

## Fees (bps; configurable)

- Regular sell fee: 100 bps on sale price (seller pays).
- External aggregation fee: 100 bps collected from buyer on purchases fulfilled via external markets; included in the upfront quote so the buyer sees the total price. Combined with the regular sell fee, external buys total 200 bps.
- LBO fee: 200 bps paid by buyer; composed of:
  - Financed fee: 100 bps added to loan principal (no upfront payment).
  - Explicit fee: 100 bps charged at checkout.
  - Default split on the total 200 bps: 50 bps to lenders as premium and 150 bps to protocol treasury; both shares configurable.
- No origination fee on LBO loans. Other loan protocol fees remain per loan contract policy.

### Scenario matrix (who pays what)
- Internal buy (wallet/LoanV2 listing), no LBO: seller 1%; buyer 0%.
- Internal buy with LBO: seller 1%; buyer 2% (1% financed into principal, 1% explicit at checkout).
- External buy (aggregated), no LBO: buyer 2% total (1% external buy fee + 1% platform fee), quoted upfront.
- External buy with LBO: buyer 4% total (2% external aggregate + 2% LBO where 1% is financed and 1% explicit), quoted upfront.

### Distribution
- LBO lender premium share (default 50 bps) is routed to lenders (configurable recipient, e.g., vault or rewards distributor). Remainder goes to protocol treasury (`feeRecipient`).
- Regular sell fee (1%) and external aggregation fee (1%) are credited to protocol treasury by default (configurable recipient).

---

## Minimal LoanV2 hooks (diamond‑only)

Whitelisted, narrowly scoped methods (when feasible per chain):

- setApprovedContract(diamond, enable): allow privileged flows from the diamond.
- setBorrower(tokenId, borrower): already available; diamond must be approved and token must be in custody.
- requestLoanForBorrower(tokenId, amount, params..., borrower): mirror of `requestLoan` but borrower is explicit; enforce permanent lock; callable only by diamond.
- increaseLoanForLbo(tokenId, amount, receiver): increase without origination for LBO when `msg.sender` is the diamond; send proceeds to `receiver` (diamond) to settle purchase.

Optional (not required for core flows):
- marketTransferIfNoDebt(tokenId, to): only if the protocol wants the diamond to programmatically withdraw to a wallet address. Preferred flows keep the veNFT in loan custody; users can withdraw via `claimCollateral()` or move within the ecosystem via `transferWithin40Acres`.

If hooks are not acceptable on a chain, LBO can occur post‑purchase (buyer borrows as a separate step) without no‑origination.

Notes:
- LoanV2 is upgradeable; we will keep on‑chain changes minimal, tightly scoped, and documented here. This diamond will be explicitly whitelisted for the above hooks per chain.

---

## LoanV3 inside the diamond (future)

- Implement as facets (LoanCoreFacet, LoanAccountingFacet, LoanRewardsFacet) with ERC‑7201 storage; reuse the same libraries.
- `migrateFromLoanV2(tokenId)`: prefer `LoanV2.transferWithin40Acres(toContract=diamond, ...)` to hand custody into LoanV3 facets without leaving the loan system; reconstruct position and parameters; optionally incentivize migration.
- Unified marketplace supports both LoanV2 and LoanV3 custody during transition.

---

## External adapters and cross‑chain

- Existing: `VexyAdapterFacet`, `OpenXAdapterFacet`.
- Planned adapters (roadmap): OpenXswap, Vexy (expanded features), Salvor on AVAX (support PHAR and Blackhole veNFTs). Each adapter implements the standard adapter surface and is wired through `MarketMatchingFacet`.
- Cross‑chain can be supported via a `BridgeAdapterFacet` (escrow + intent), but inherits the same safety libraries.

---

## Configuration

- `loan()` optional; when unset, loan‑custody and LBO features are disabled. Router enforces this by reverting `LoanNotConfigured` for `InternalLoan` operations.
- `loanAsset()` defines the payoff asset (e.g., USDC). Swaps to this asset use `SwapRouterLib` with slippage constraints.
- `allowedPaymentToken(token)` per chain.
- Fee recipients and bps are upgradeable via `MarketConfigFacet`.

### Governance and roles
- Owner and (optional) `MARKET_ADMIN` roles can manage: fee parameters (seller, external, LBO fee and split), adapter allowlists, LBO enable/disable per chain, pausing, and loan integration settings.
- Roles provide the security base as the diamond grows into a full veNFT market and lending platform.

---

## Roadmap & checklist

Phase A (market core)
- [ ] Finalize internal listing/offer/matching facets
  - Ensure `MarketListingsWalletFacet` uses CEI, supports Permit2 optional path, ODOS swap path, and has lifecycle tests (make/update/cancel/take/quote) including pause/reentrancy.
  - Ensure `MarketListingsLoanFacet` handles payoff in `loanAsset`, borrower handoff via `setBorrower`, ODOS swap path for input tokens, Permit2 optional path; tests for quoting (price/fee/total), settlement, balances, and guards.
  - Ensure `MarketOfferFacet` enforces weight/debt/expiry criteria; settlement for wallet-held vs loan-custodied flows; tests for create/update/cancel/accept and failure cases.
  - Ensure `MarketMatchingFacet` covers wallet↔offer and loan↔offer matching with full settlement tests and CEI.
- [ ] External adapter path via router
  - Add adapter registry admin function in `MarketConfigFacet`: `setExternalAdapter(bytes32 key, address facet)` (owner or MARKET_ADMIN), plus `ExternalAdapterSet(key, facet)` event; disallow zero address.
  - Define minimal adapter interface used by router: `quoteToken(uint256 tokenId, bytes quoteData) → (uint256 price, uint256 fee, address currency)` and uniform `buyToken(uint256 tokenId, uint256 maxPaymentTotal, address inputAsset, uint256 maxInputAmount, bytes tradeData, bytes marketData, bytes optionalPermit2)`.
  - Implement `MarketRouterFacet.quoteToken` for `ExternalAdapter` route: look up adapter by key, delegatecall `quoteToken`, bubble up reverts.
  - The router’s external branch delegatecalls adapter `buyToken` with separate parameters (no packed bytes). Reverts are bubbled via `RevertHelper`.
  - Update `VexyAdapterFacet` (or add a thin wrapper facet) to implement the generic `quoteToken/buyToken` so it can be invoked via the router; keep `takeVexyListing` as an optional convenience that forwards to the generic entry.
- [ ] External matching improvements (Vexy)
  - In `matchOfferWithVexyListing`, add swap path when `offer.paymentToken != currency`: use Permit2 (if provided) to pull `offer.price`, execute ODOS trade with allowance bump/reset, and enforce balance-delta slippage to cover `extPrice` and fee.
  - After adapter buy, assert custody with `TransferGuardsLib.requireCustody(votingEscrow, tokenId, address(this))` before transferring to the offer creator.
- [ ] Fees and safety polish
  - Verify fee computation per route (`InternalWallet`, `InternalLoan`, `ExternalAdapter`) via tests; ensure fee recipient receives correct amount and seller receives remainder.
  - Zero approvals after all external calls (ODOS, marketplaces); add tests that no lingering approvals remain.
  - Extend transfer guards where applicable to ensure no-debt-before-transfer for any future transfer paths; maintain CEI and nonReentrant across new flows.
- [ ] Tests (expand coverage)
  - Router: external quote success and revert cases (UnknownAdapter, invalid key, adapter revert, bad currency).
  - Router: external buy success and revert cases (maxPaymentTotal exceeded, currency not allowed, price out of bounds, adapter revert propagation).
  - Adapter registry: admin-only, zero-address rejections, event assertions; querying via `MarketViewFacet` if exposed.
  - External matching: direct-currency path and swap path; custody assertion before delivery; pause/reentrancy coverage.
  - Fee paths: assert correct fee amounts and recipients across all routes.
- [ ] Adapters roadmap
  - Implement stubs for `OpenXswap` and `Salvor` following the same adapter interface; wire via registry and add basic quote/buy tests.

Phase B (LBO on LoanV2 chains)
- [ ] LoanV2 whitelisting and minimal hooks
- [ ] LBO orchestration + fee distribution (config: `sellerFeeBps`, `externalAggregationFeeBps`, `lboFinancedFeeBps`, `lboExplicitFeeBps`, `lboLenderPremiumShareBps`)
- [ ] External LBO safeguards (vault credit caps, min downpayment, allowed marketplaces, post‑purchase custody checks, full‑tx atomicity)
- [ ] E2E: wallet listing LBO, LoanV2 listing LBO, Vexy LBO

Phase C (LoanV3 facets in‑diamond)
- [ ] Define ERC‑7201 storage + facets; parity with LoanV2 where reasonable
- [ ] Migration flow and optional incentives; dual‑custody support in market

Phase D (aggregation and polish)
- [ ] Additional external adapters; preview/quote endpoints; batch routes
- [ ] Royalties (optional), richer operator approvals, audits/formal checks, mainnet rollout

---

## Reference

- See `src/LoanV2.sol` for current loan logic (locking, payoff, fees, borrower handover via `setBorrower`).
- See `src/facets/market/VexyAdapterFacet.sol` for the external adapter pattern.


