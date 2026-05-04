## 40 Acres Loan Contracts

[Bug Bounty](https://audits.sherlock.xyz/bug-bounties/102)

## Security Warning

**We will NEVER:**
- Recruit through unsolicited LinkedIn/GitHub interactions
- Ask you to run code from unknown, unverified sources, or private repos
- DM you job offers

**Our only official channels:**
- Website: [40acres.finance](https://40acres.finance)
- Docs: [docs.40acres.finance](https://docs.40acres.finance/)
- Twitter: [@40acres_Finance](https://x.com/40acres_Finance)
- Discord: [Discord](https://discord.gg/7f8mjjd8bM)
- GitHub: [github.com/40-Acres](https://github.com/40-Acres)

If you were approached by anyone claiming to be 40 Acres Finance outside of these channels, **do not run any code or connect your wallet.**

## Overview

40 Acres provides utility for veNFT holders including instant access to loans based on their veNFTs future revenue. Each week the veNFT rewards are used to repay the loan automatically. Additionally, veNFTs can be listed on the marketplace and purchased with or without outstanding loans. Supports aggregation of external markets and leveraged buyouts of veNFTs using fla

### Portfolio Accounts Architecture

Portfolio Accounts use a hierarchical diamond proxy pattern where each user gets a dedicated account (diamond proxy) whose facets are managed centrally via a `FacetRegistry`. Different deployment types register different facets depending on the protocol integration.

```
PortfolioManager (central hub - deploys factories, enforces collateral)
    └── PortfolioFactory + FacetRegistry (one per deployment type)
            └── FortyAcresPortfolioAccount (per user - diamond proxy)
```

Each factory type registers a specific set of facets:

#### Aerodrome / Velodrome Factory

Full-featured deployment for veAERO/veVELO collateral with marketplace, voting, rewards processing, and lending.

| Facet | Functions |
|-------|-----------|
| **CollateralFacet** | addCollateral, removeCollateral, getTotalLockedCollateral, getTotalDebt, getMaxLoan, getOriginTimestamp, getCollateralToken, getLockedCollateral, enforceCollateralRequirements |
| **LendingFacet** | borrow, pay, setTopUp, topUp |
| **ClaimingFacet** | claimFees, claimRebase, claimLaunchpadToken |
| **VotingFacet** | vote, voteForLaunchpadToken, setVotingMode, isManualVoting, defaultVote |
| **VotingEscrowFacet** | increaseLock, createLock, merge |
| **MigrationFacet** | migrate |
| **MarketplaceFacet** | processPayment, finalizePurchase, buyMarketplaceListing, getListing, makeListing, cancelListing |
| **RewardsProcessingFacet** | processRewards, setRewardsOption, getRewardsOption, getRewardsOptionPercentage, setRewardsToken, setRecipient, setRewardsOptionPercentage, getRewardsToken, swapToRewardsToken, swapToRewardsTokenMultiple |
| **ERC721ReceiverFacet** | onERC721Received |

#### veYieldBasis Factory

Deployment for veYB locking, gauge voting, and rewards distribution against a `DynamicFeesVault`. Uses `DynamicCollateralFacet` (veYB acts as the underlying voting-escrow collateral) and a `veYieldBasisAdapter` to bridge the veYB ABI to the standard `IVotingEscrow` interface. See [`script/portfolio_account/yieldbasis/DeployYieldBasis.s.sol`](script/portfolio_account/yieldbasis/DeployYieldBasis.s.sol).

| Facet | Functions |
|-------|-----------|
| **DynamicCollateralFacet** | addCollateral, removeCollateral, getTotalLockedCollateral, getTotalDebt, getMaxLoan, getOriginTimestamp, getCollateralToken, getLoanUtilization, enforceCollateralRequirements |
| **veYieldBasisFacet** | createLock, increaseLock, depositLock, onERC721Received |
| **veYieldBasisVotingFacet** | vote, defaultVote |
| **veYieldBasisRewardsProcessingFacet** | processRewards, getRewardsToken, swapToRewardsToken, swapToRewardsTokenMultiple, calculateRoutes |
| **RewardsConfigFacet** | setRecipient, setZeroBalanceDistribution, getZeroBalanceDistribution, clearZeroBalanceDistribution, setActiveBalanceDistribution, getActiveBalanceDistribution, clearActiveBalanceDistribution |

#### YieldBasis LP Factory

Deployment for borrowing the underlying asset (e.g. WETH, WBTC, cbBTC) against gauge-staked YieldBasis LP collateral. Uses a per-market `LendingVault` (ERC4626) that lends directly to portfolio accounts — there is no separate Loan contract. The `YieldBasisLpFacet` itself implements `ICollateralFacet` (its own collateral storage), and the `YieldBasisLpLendingFacet` reads gauge shares as collateral. See [`script/portfolio_account/yieldbasis/DeployYieldBasisLp.s.sol`](script/portfolio_account/yieldbasis/DeployYieldBasisLp.s.sol).

| Facet | Functions |
|-------|-----------|
| **YieldBasisLpFacet** | deposit, withdraw, setStakedMode, getStakingState, getTotalLockedCollateral, getTotalDebt, getMaxLoan, enforceCollateralRequirements, getLoanUtilization, getCollateralToken |
| **YieldBasisLpLendingFacet** | borrow, pay |
| **YieldBasisLpClaimingFacet** | claimGaugeRewards, previewGaugeRewards, harvestLpFees, getAvailableLpFeeYield, getDepositInfo |
| **YieldBasisLpRewardsProcessingFacet** | processRewards, getRewardsToken, swapToRewardsToken, swapToRewardsTokenMultiple, calculateRoutes |
| **RewardsConfigFacet** | setRecipient, setZeroBalanceDistribution, getZeroBalanceDistribution, clearZeroBalanceDistribution, setActiveBalanceDistribution, getActiveBalanceDistribution, clearActiveBalanceDistribution |

#### Wallet Factory

Lightweight wallet deployment for cross-portfolio asset transfers, token swaps, and veNFT lock creation. No collateral enforcement — `enforceCollateralRequirements` always returns true.

| Facet | Functions |
|-------|-----------|
| **WalletFacet** | enforceCollateralRequirements, transferERC20, transferNFT, swap, createLock |
| **VexyFacet** | buyVexyListing |
| **OpenXFacet** | buyOpenXListing |

#### ERC4626 Vault Factory

Deployment for borrowing against ERC4626 vault share collateral (e.g. LP positions). Uses a separate collateral manager (`ERC4626CollateralManager`) with vault share valuation.

| Facet | Functions |
|-------|-----------|
| **ERC4626CollateralFacet** | addCollateral, addCollateralFrom, removeCollateral, getTotalLockedCollateral, getTotalDebt, getMaxLoan, getOriginTimestamp, getCollateralVault, getLockedCollateral, enforceCollateralRequirements, getCollateralToken |
| **ERC4626LendingFacet** | borrow, pay |
| **ERC4626ClaimingFacet** | claimVaultYield, getAvailableYield, getDepositInfo |

## Testing

The test suite is split into **local tests** (no network access required) and **fork tests** (require RPC endpoints to fork live chains).

### Test Directory Structure

```
test/
├── portfolio_account/     # Local tests (no fork required)
│   ├── collateral/        # CollateralFacet, ERC4626CollateralFacet
│   ├── lending/           # LendingFacet, DynamicLendingFacet
│   ├── marketplace/       # MarketplaceFacet, DynamicMarketplaceFacet
│   ├── vault/             # DynamicFeesVault
│   ├── vote/              # VotingFacet
│   ├── votingEscrow/      # VotingEscrowFacet
│   ├── wallet/            # WalletFacet
│   ├── rewards_processing/# RewardsProcessingFacet
│   ├── erc4626/           # ERC4626 claiming
│   ├── regression/        # Regression tests
│   └── utils/             # Shared test setups (DynamicLocalSetup, etc.)
├── accounts/              # PortfolioManager, PortfolioFactory local tests
├── integration/           # Local integration tests
├── Vault.t.sol            # Vault local tests
├── EntryPoint.t.sol       # EntryPoint tests
├── mocks/                 # Mock contracts for local testing
├── utils/                 # Shared test utilities
└── fork/                  # Fork tests (require RPC endpoints)
    ├── Loan.t.sol         # Loan fork tests (Base)
    ├── VeloLoan.t.sol     # Velodrome loan tests (Optimism)
    ├── Blackhole.t.sol    # Blackhole tests (Avalanche)
    ├── XPharaoh.t.sol     # Pharaoh tests (Avalanche)
    ├── Swapper.t.sol      # Swapper tests (Base)
    ├── LoanUpgrade.t.sol  # Upgrade tests (Base)
    ├── accounts/           # PortfolioManager fork tests (Base, Optimism)
    ├── integration/        # Integration fork tests (Base, Optimism, Ink)
    └── portfolio_account/  # Portfolio account fork tests
        ├── e2e/            # End-to-end (Base, Ethereum)
        ├── live/           # Live deployment validation (Base)
        ├── marketplace/    # Marketplace fork tests (Base)
        ├── regression/     # Regression fork tests (Base)
        ├── bridge/         # Bridge tests (Ink)
        ├── vote/           # Superchain voting (Optimism)
        └── yieldbasis/     # YieldBasis tests (Ethereum)
```

### Running Local Tests (No RPC Required)

```bash
# Run all local tests (default profile excludes test/fork/**)
forge test

# Run a specific test by name
forge test --match-test testFunctionName

# Run tests in a specific file
forge test --match-path test/portfolio_account/collateral/CollateralFacet.t.sol

# Run tests in a directory
forge test --match-path "test/portfolio_account/marketplace/*"

# Verbose output (show logs, traces on failure)
forge test -vv        # Logs
forge test -vvv       # Traces on failure
forge test -vvvv      # All traces
```

### Running Fork Tests (Requires RPC Endpoints)

Fork tests run against live chain state and require RPC endpoints set as environment variables.

**Required environment variables:**

| Variable | Chain | Used By |
|----------|-------|---------|
| `BASE_RPC_URL` | Base | Most fork tests (Loan, Swapper, Portfolio, Marketplace, E2E, Live, Regression) |
| `OP_RPC_URL` | Optimism | VeloLoan, PortfolioManager, Superchain voting, integration |
| `AVAX_RPC_URL` | Avalanche | Blackhole, XPharaoh |
| `ETH_RPC_URL` | Ethereum | YieldBasis (voting, rewards processing), YieldBasis E2E |
| `INK_RPC_URL` | Ink | BridgeFacet, Superchain integration |

```bash
# Set RPC endpoints (use your own Alchemy/Infura/etc. URLs)
export BASE_RPC_URL="https://base-mainnet.g.alchemy.com/v2/YOUR_KEY"
export OP_RPC_URL="https://opt-mainnet.g.alchemy.com/v2/YOUR_KEY"
export AVAX_RPC_URL="https://avax-mainnet.g.alchemy.com/v2/YOUR_KEY"
export ETH_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
export INK_RPC_URL="https://ink-mainnet.g.alchemy.com/v2/YOUR_KEY"

# Run ALL fork tests
FOUNDRY_PROFILE=fork forge test

# Run specific fork test files
FOUNDRY_PROFILE=fork forge test --match-path test/fork/Loan.t.sol

# Run fork tests for a specific directory
FOUNDRY_PROFILE=fork forge test --match-path "test/fork/portfolio_account/e2e/*"

# Run a single fork test by name
FOUNDRY_PROFILE=fork forge test --match-test testSpecificFunction
```

### Running All Tests (Local + Fork)

```bash
# Ensure all RPC env vars are set, then:
forge test && FOUNDRY_PROFILE=fork forge test
```

### Coverage

```bash
forge coverage
```

### Foundry Profiles

| Profile | Description |
|---------|-------------|
| `default` | Local tests only. Excludes `test/fork/**`. |
| `fork` | Fork tests only. Matches `test/fork/**`. Requires RPC env vars. |
| `ci` | CI profile with 256 fuzz runs. |

> **Note:** Never use `forge build --force` or `forge clean && forge build`. The via-ir pipeline is slow — rely on incremental builds.

## Deployment

### Scripts
- [BaseDeploy.s.sol](script/BaseDeploy.s.sol) - Base deployment script
- [NativeVaultDeploy.s.sol](script/NativeVaultDeploy.s.sol) - Native vault deployment
- [EntryPointDeploy.s.sol](script/EntryPointDeploy.s.sol) - Entry point deployment
- [PharaohDeploy.s.sol](script/PharaohDeploy.s.sol) - Pharaoh contract deployment

## Key Features
- Automatic loan repayment using veNFT rewards
- Purchase of veNFTs with outstanding loans
- Aggregated veNFT marketplace with support for external markets and leveraged buyouts using flash loans
