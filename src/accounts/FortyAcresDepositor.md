# FortyAcresDepositor: one fixed spender for every portfolio deposit

## Problem

Portfolio accounts are CREATE2 diamonds created lazily inside the user's first
`PortfolioManager.multicall`. The frontend predicted the account address and asked
the user to `approve(predictedAccount, tokenId)`. At that moment there is no code
at the spender, so wallet risk engines (OKX, Rabby, Blockaid, GoPlus) flag it:

> Address type: EOA. Danger. "The spender address is an Externally Owned Account,
> potentially a scam address"

Even once deployed, a per-user account is a fresh, unlabeled, zero-trust contract
only that user ever touches. It can never build reputation.

## Design

`FortyAcresDepositor` (`src/accounts/FortyAcresDepositor.sol`) is one fixed,
verified, labeled contract per chain. It is the only address users approve:

- `setApprovalForAll(depositor, true)` once per veNFT collection, or
  `approve(depositor, tokenId)` per token
- `approve(depositor, amount)` per ERC20

It is a standalone **push** contract. **No core contract changes.**

```
user ──deposit721(factory, ve, id)──▶ FortyAcresDepositor
                                          │ factory registered with one of the fixed managers?
                                          │ portfolio = factory.portfolioOf(msg.sender)
                                          │            or factory.createAccount(msg.sender)
                                          ▼
                                     ve.safeTransferFrom(msg.sender, portfolio, id)
                                          │
                                          ▼
                                     portfolio.onERC721Received  (VotingEscrowFacet)
                                          └─ CollateralManager.addLockedCollateral(id)
```

The portfolio receives the asset exactly as it would from the user's wallet. On
veNFT platforms (Aerodrome, Velodrome, Blackhole) the account's
`onERC721Received` registers the token as collateral on receipt, so a deposit is
**one transaction** after the one-time approval. Borrowing is the usual
`multicall([borrow])` afterwards. Assets that need an explicit facet call are
added through the usual multicall, which already accepts balances sitting in the
account (`ERC4626CollateralFacet.addCollateral(shares)`, `addCollateral(tokenId)`
for a token already owned by the account).

### Trust surface

- **No owner, no upgrade, no setters.** The manager set is fixed in the constructor.
- `from` is always `msg.sender`; the destination is always `msg.sender`'s own
  portfolio at a factory registered with one of the managers. An approval to this
  contract can only ever move the approver's assets into the approver's account.
- Never holds a balance. `nonReentrant` on both deposits (the ERC721 receiver
  callback re-enters the portfolio, not this contract, but the guard is cheap).
- `createAccount` is already permissionless on the factory and registers the
  account with its manager itself.

### What stays as before

Actions that pull from the owner inside a facet (`increaseLock`, `createLock`
from an ERC20, `pay`, YieldBasis LP `deposit`) keep their per-account approval.
Those happen after the account exists, so wallets show a contract, not an EOA.
Routing them through the depositor would require facet changes and an audit; it
was considered and deliberately dropped.

## Rollout (per chain)

1. Merge. Nothing changes on-chain.
2. `DeployFortyAcresDepositor.s.sol` with `PORTFOLIO_MANAGERS` = every manager
   on the chain (Base: aerodrome + hydrex). CREATE2, verify.
3. Add `"depositor": { "dev", "prod" }` to `addresses/<network>/<platform>.json`
   (same address in every platform file of that chain), changeset `patch`, publish.
4. Frontend switches the deposit spender to `depositor` and calls `deposit721`.
5. Submit the address for labeling: GoPlus, Blockaid, OKX Web3 wallet, Rabby,
   explorer "Protocol" tag.

## Frontend follow-up

- Spender for deposits becomes the registry `depositor`, not the predicted account.
- Approval: `setApprovalForAll(depositor, true)` (default) or per-token
  `approve(depositor, tokenId)`. Both work with the same contract.
- Deposit: `depositor.deposit721(factory, ve, tokenId)`; on platforms with the
  plain `ERC721ReceiverFacet`, follow with `multicall([addCollateral(tokenId)])`.
- Checks: `depositor.isApproved721(ve, owner, tokenId)`,
  `depositor.allowance20(token, owner)`, `depositor.portfolioOf(factory, user)`.
