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

- DebtSettlementLib
  - Compute payoff and call loan `pay()` with the correct asset; handle residuals; canonical events.
  - LBO primitives: compute max borrow with LTV discount; apply LBO fees; distribute lender premium; ensure no origination fee path.

- ListingValidationLib
  - Owner/operator checks; approval/expiry; price/currency allowlist; optional signature schema for off‑chain orders.

- SwapRouterLib
  - Unified swap via ODOS; allowance bump/reset; balance‑delta slippage checks; safe low‑level calls.

- ExternalMarketLib
  - Standard adapter interface: read listing, validate, purchase, return NFT custody to diamond.

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

- Leveraged Buyout (LBO)
  - Buyer acquires a veNFT and simultaneously opens a loan to finance it.
  - Fees: 2% LBO fee (buyer), 1% seller fee; no origination for the LBO loan; LTV discount of 1% (configurable) for safety.
  - Wallet/external source: diamond temporarily escrows the NFT, locks into loan custodian, opens loan for buyer with LTV minus discount, directs proceeds to settle purchase, then assigns borrower.
  - LoanV2 listing source: pay off existing debt, assign borrower, optionally open a new loan immediately under the LBO rules.

---

## Fees (bps; configurable)

- Regular sell fee: 100 bps on sale price (seller pays).
- External aggregation fee: 100 bps collected from buyer on purchases fulfilled via external markets; included in the upfront quote so the buyer sees the total price. Combined with the regular sell fee, external buys total 200 bps.
- LBO fee: 200 bps paid by buyer; default split 50 bps to lenders as premium and 150 bps to protocol treasury; both shares configurable.
- LBO LTV discount: 100 bps subtracted from max LTV for LBO because it is borrowed as the fee (effectively baking ~1% of cost into the loan capacity). The remaining 1% of the LBO fee is charged explicitly at checkout.
- No origination fee on LBO loans. Other loan protocol fees remain per loan contract policy.

### Scenario matrix (who pays what)
- Internal buy (wallet/LoanV2 listing), no LBO: seller 1%; buyer 0%.
- Internal buy with LBO: seller 1%; buyer 2% (1% via LTV reduction [because it is borrowed as part of the LBO], 1% explicit at checkout).
- External buy (aggregated), no LBO: buyer 2% total (1% external buy fee + 1% platform fee), quoted upfront.
- External buy with LBO: buyer 4% total (2% external aggregate + 2% LBO where 1% is via LTV reduction [because it is borrowed as part of the LBO] and 1% explicit), quoted upfront.

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
- [ ] Implement TransferGuardsLib, DebtSettlementLib, ListingValidationLib, SwapRouterLib, ExternalMarketLib
- [ ] Finish `MarketListingsWalletFacet`, `MarketListingsLoanFacet`, `MarketOfferFacet`, `MarketMatchingFacet`
- [ ] Vexy adapter buy path (no LBO), tests for invariants and CEI
- [ ] Add adapters: OpenXswap, Salvor (AVAX; PHAR/Blackhole collections)

Phase B (LBO on LoanV2 chains)
- [ ] LoanV2 whitelisting and minimal hooks
- [ ] LBO orchestration + fee distribution (config: `sellerFeeBps`, `lboFeeBps`, `lboLenderPremiumShareBps`, `lboLtvDiscountBps`)
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


