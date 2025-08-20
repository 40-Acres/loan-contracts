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

All facets call shared internal libraries for invariants and settlement to guarantee consistent safety.

---

## Safety by construction (internal libraries)

Facets must compose these libraries; do not bypass them:

- TransferGuardsLib
  - Enforce no‑debt‑before‑transfer when veNFT is loan‑custodied.
  - Check permanent lock state; ensure receiver is allowed; zero approvals after transfers/swaps.

- SwapRouterLib
  - Unified swap via ODOS; allowance bump/reset; balance‑delta slippage checks; safe low‑level calls.

- AccessControlLib
  - Owner and optional AccessManager role gates (MARKET_ADMIN) for config/fees/pausing.

---

## Core invariants

- If a veNFT is in loan custody (LoanV2/LoanV3), outstanding debt must be fully paid before any transfer away from the custodian.
- All flows follow CEI, are nonReentrant, and perform external calls last.
- Payoff asset must equal `loanAsset()` unless a swap is executed with explicit slippage bounds.
- Infinite approvals granted only when necessary and zeroed immediately after use.

---

## Primary flows

- Wallet listing → take
  - Validate listing; pull funds; transfer via `votingEscrow.transferFrom(seller → buyer)`; apply marketplace fees; optional royalties.

- LoanV2 listing → take (payoff required)
  - Validate; collect funds; swap to `loanAsset` if needed; `DebtSettlementLib.payoff(LoanV2, tokenId)`; set borrower to buyer via `LoanV2.setBorrower` (diamond must be approved/whitelisted). By default we do not transfer the veNFT out; it remains in loan custody so the buyer can borrow later. If the buyer wishes to withdraw, they can call `claimCollateral()` themselves; for intra‑40 Acres moves, use `LoanV2.transferWithin40Acres`.

- External listing (e.g., Vexy) → take
  - Validate external state/price/currency; pull buyer funds; include external aggregation fee in upfront quote; `VexyAdapterFacet.buyVexyListing`; deliver NFT to buyer (or keep in escrow for LBO).

## Quoting and buying API (enum‑driven)

We define an enum route type and a registry of external markets per chain.

- Route enum (`RouteLib.BuyRoute`): `InternalWallet`, `InternalLoan`, `ExternalAdapter`.
- External markets are identified by `bytes32` keys (e.g., `VEXY`, `OPENX`, `SALVOR`) resolved to adapter addresses in config.
- Single‑veNFT per diamond: each deployment binds to one `votingEscrow`. All token IDs refer to this veNFT. For a new veNFT market/lending, deploy a new diamond. This simplifies routing and reduces attack surface.

Selectors
- quoteToken(route, marketKey, tokenId, quoteData) → (price, marketFee, total, currency)
  - Internal routes ignore `marketKey`; external routes use it to find the adapter. `quoteData` is adapter‑specific (Phase A default: `abi.encode(listingId, expectedCurrency, maxPrice)`).
- buyToken(route, marketKey, tokenId, maxTotal, buyData, optionalPermit2)
  - Executes the purchase through the selected path and enforces `total <= maxTotal`. For external routes, `buyData` must match the adapter’s expected tuple; optional Permit2 payload allows single‑tx funds pull.

Registry and allowlists
- `marketKey → adapter` registry controlled by governance; unknown keys revert.
- `votingEscrow` allowlist controlled by governance; adapters may also maintain per‑adapter allowlists.

This keeps the API stable while allowing new external venues via governance without changing selectors.

### RFQ off‑chain orders and Permit2
- EIP‑712 typed orders (Ask/Bid) signed off‑chain: include route, marketKey, votingEscrow, tokenId, maker, optional taker, currency, price, expiry, nonce/salt, and `dataHash = keccak256(buyData)`.
- On‑chain fill (`takeOrder`) verifies signature, nonce (replay‑protection), expiry, and `keccak256(buyData)` equality, then calls `buyToken` with the same (route, marketKey, votingEscrow, tokenId, maxTotal, buyData).
- Makers can cancel via nonce bump or explicit cancel. Permit2 is supported in `buyToken/takeOrder` to pull exact funds without prior ERC20 approvals.

### LBO UX and indexing for external venues
- UI calls `quoteToken` with `ExternalAdapter` and `abi.encode(listingId, expectedCurrency, maxPrice)` and displays: price, fees, total, projected loan principal, financed LBO fee portion, and max LTV.
- Required indexed fields per listing: `(votingEscrow, tokenId)`, `marketKey`, `listingId`, `expectedCurrency`, current price, endTime/sold flag. Loan inputs for preview: `loanAsset`, LTV caps, LBO fee config.
- `buyToken` with LBO flag performs: adapter buy to diamond custody → custody assert → lock into loan → open loan sized to LTV + financed fee → settle seller and fees → assign borrower.

### Why a single routed API (with optional wrappers)
- Pros: stable ABI, easy integrations (one quote/buy path), consistent fees/safety, governance can add adapters without changing selectors.
- Cons: a small routing overhead and use of `bytes` for adapter data.
- Pattern: keep `quoteToken/buyToken` as core; expose optional convenience wrappers (e.g., `buyInternalWallet`, `buyInternalLoan`, `buyVexy`) that forward to the router for readability.

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

- Existing: `VexyAdapterFacet`.
- Planned adapters (roadmap): OpenXswap, Vexy (expanded features), Salvor on AVAX (support PHAR and Blackhole veNFTs). Each adapter implements the standard adapter surface and is wired through `MarketMatchingFacet`.
- Cross‑chain can be supported via a `BridgeAdapterFacet` (escrow + intent), but inherits the same safety libraries.

---

## Configuration

- `loan()` optional; when unset, loan‑custody and LBO features are disabled.
- `loanAsset()` defines the payoff asset (e.g., USDC). Swaps to this asset use `SwapRouterLib` with slippage constraints.
- `allowedPaymentToken(token)` per chain.
- Fee recipients and bps are upgradeable via `MarketConfigFacet`.

### Governance and roles
- Owner and (optional) `MARKET_ADMIN` roles can manage: fee parameters (seller, external, LBO fee and split), adapter allowlists, LBO enable/disable per chain, pausing, and loan integration settings.
- Roles provide the security base as the diamond grows into a full veNFT market and lending platform.

---

## Roadmap & checklist

Phase A (market core)
- [ ] Implement TransferGuardsLib, DebtSettlementLib, SwapRouterLib
- [ ] Finish `MarketListingsWalletFacet`, `MarketListingsLoanFacet`, `MarketOfferFacet`, `MarketMatchingFacet`
- [ ] Vexy adapter buy path (no LBO), tests for invariants and CEI
- [ ] Add adapters: OpenXswap, Salvor (AVAX; PHAR/Blackhole collections)

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

The diamond enforces safety through internal libraries so new adapters and future cross‑chain integrations can be added without compromising invariants.


