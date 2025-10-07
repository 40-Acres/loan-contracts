# Market Diamond Deployment Scripts

## Overview

Deploy market diamonds with a simple copy-paste approach. Each market has its own pair of deployment scripts with all configuration marked in file.

## Quick Start

### AERO Market on Base

**Step 1: Deploy Market Diamond**
```bash
PRIVATE_KEY=0x... forge script script/MarketDeployInitAERO.s.sol:MarketDeployInitAERO \
  --rpc-url $BASE_RPC_URL --broadcast --verify
```

**Step 2: Enable Loan Listings (Optional)**

After Step 1, update the addresses in `MarketDeployLoanListingsAERO.s.sol`:
- `DIAMOND_ADDRESS` - from Step 1 output
- `LOAN_LISTINGS_FACET_ADDRESS` - from Step 1 output

Then run:
```bash
PRIVATE_KEY=0x... forge script script/MarketDeployLoanListingsAERO.s.sol:MarketDeployLoanListingsAERO \
  --rpc-url $BASE_RPC_URL --broadcast
```

## Creating a New Market

Copy the MarketDeployInit and MarketDeployLoanListings and configure for new market. Tip: CTRL+F `@dev Configure`


## Script Structure

### Script 1: Deploy Market (`MarketDeploy*.s.sol`)

**What it deploys:**
- Diamond proxy with all facets
- Wallet listings, offers, matching, router
- External adapters (Vexy, OpenX)

**What works after Script 1:**
- ✅ Wallet listings (NFTs in user wallets)
- ✅ External marketplace integrations
- ✅ Offers and matching
- ✅ All payment tokens

**What requires Script 2:**
- ❌ Loan listings (NFTs in loan custody)
- ❌ LBO (Leveraged Buyout)
- ❌ Flash loans

### Script 2: Enable Loan Features (`MarketLoanListings*.s.sol`)

**What it does:**
- Connects LoanV2 contract
- Adds loan listing functions
- Enables LBO functionality
- Configures flash loan support

**Prerequisites:**
- Script 1 completed
- LoanV2 deployed with market functionality

## Notes

- Each market is independent and has its own diamond proxy
- Markets are tied to specific loan contracts and voting escrow tokens
- To deploy on a new chain: copy script, update addresses, deploy
- To deploy a new market on same chain: copy script, update addresses, deploy
- All configuration is version controlled in the script file itself

