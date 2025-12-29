# Portfolio Accounts

Portfolio Accounts are smart contract wallets that enable users to manage their DeFi positions, loans, and collateral across multiple protocols. The system is built on a diamond proxy pattern with a centralized facet registry, allowing for modular functionality and upgradeability.

## Architecture Overview

### Portfolio Manager - Entry Point for Users

The **PortfolioManager** is the central entry point for all user interactions with portfolio accounts. It provides a unified interface for executing operations across multiple portfolio accounts in a single transaction.

#### Multicall Method

The `multicall` function allows users to execute multiple function calls across different portfolio accounts atomically:

```solidity
function multicall(
    bytes[] calldata calldatas,
    address[] calldata portfolios
) external returns (bytes[] memory results)
```

**Key Features:**
- **Cross-Account Operations**: Execute calls on multiple portfolio accounts in one transaction
- **Ownership Verification**: Automatically verifies that `msg.sender` owns all specified portfolio accounts
- **Atomic Execution**: All calls succeed or the entire transaction reverts
- **Automatic Collateral Enforcement**: After all calls execute, `enforceCollateral()` is automatically called on each portfolio account to ensure collateral ratios remain within acceptable ranges

**Example Usage:**
```solidity
// Prepare calls for multiple portfolio accounts
bytes[] memory calldatas = new bytes[](2);
address[] memory portfolios = new address[](2);

// Call 1: Request loan on Aerodrome-USDC portfolio
calldatas[0] = abi.encodeWithSelector(
    LendingFacet.requestLoan.selector,
    tokenId,
    loanContract,
    amount
);
portfolios[0] = aerodromeUSDCAccount;

// Call 2: Vote on Aerodrome-Relayer portfolio
calldatas[1] = abi.encodeWithSelector(
    VotingFacet.vote.selector,
    pools,
    weights
);
portfolios[1] = aerodromeRelayerAccount;

// Execute multicall
portfolioManager.multicall(calldatas, portfolios);
```

### Portfolio Factories - Deterministic Deployment

**PortfolioFactory** contracts are deployed using CREATE2 with deterministic salts, ensuring they have the **same address across different networks** (e.g., Base, Optimism, Ethereum).

#### Deterministic Deployment Process

1. **Factory Deployment**: The PortfolioManager deploys factories using CREATE2 with a salt derived from the platform name (e.g., "Aerodrome")
2. **Same Address Guarantee**: Using the same deployer address and salt on different networks results in identical factory addresses
3. **FacetRegistry Association**: Each factory is paired with its own FacetRegistry, also deployed deterministically

**Deployment Example:**
```solidity
// Deploy factory with deterministic salt
bytes32 salt = keccak256(abi.encodePacked("Aerodrome"));
(PortfolioFactory factory, FacetRegistry registry) = portfolioManager.deployFactory(salt);

// This factory will have the same address on Base, Optimism, and other networks
// when deployed with the same salt and deployer address
```

**Benefits:**
- **Cross-Chain Consistency**: Same factory address across all networks simplifies integration
- **Predictable Addresses**: Frontends and integrations can hardcode factory addresses
- **Gas Efficiency**: Users can interact with known addresses without lookups

### Collateral Enforcement

The `multicall` function uses an `enforceCollateral` modifier that automatically tracks debt before operations and enforces collateral requirements after operations complete. This ensures all portfolio accounts maintain valid collateral ratios while preventing users from being locked out when overcollateralized.

#### How It Works

1. **Before Operations**: The `enforceCollateral` modifier tracks each portfolio account's debt before executing any operations
2. **Execute All Calls**: All function calls in the multicall are executed
3. **Collateral Check**: After operations, the modifier checks each portfolio account
4. **Validation**: For each portfolio, the modifier verifies that either:
   - The debt is within valid range (debt ≤ maxLoan), OR
   - The debt did not increase (debt ≤ previousDebt)
5. **Revert on Violation**: If debt increased AND the account is overcollateralized, the entire transaction reverts


This ensures that:
- Users cannot withdraw collateral that would make their position undercollateralized
- Debt cannot exceed the maximum allowed based on locked collateral
- All portfolio accounts maintain healthy collateral ratios after any operation
- **Overcollateralization Protection**: If a user becomes overcollateralized due to rewards rate decreases, they are **not locked out**. The system allows operations that:
  - **Pay back debt** (debt decreases) - always allowed, even when overcollateralized
  - **Add collateral** (debt stays same, maxLoan increases) - allowed when overcollateralized
  - **Don't increase debt** - any operation that doesn't worsen the position is allowed
  - **Prevent borrowing more** - debt cannot increase when already overcollateralized

## Portfolio Account Structure

### Single Use Case Design

Each portfolio account is designed for a **single, specific use case**. This design pattern ensures:

- **Clear Separation of Concerns**: Each account has a well-defined purpose
- **Simplified Management**: Users can easily identify which account handles which protocol/asset
- **Gas Efficiency**: Smaller, focused accounts are more gas-efficient
- **Security**: Isolated accounts reduce attack surface

### Example Use Cases

#### 1. Aerodrome-USDC Portfolio
- **Purpose**: Manage loans and collateral for users borrowing USDC against veAERO tokens
- **Features**:
  - Lock veAERO tokens as collateral
  - Borrow USDC from the loan contract
  - Vote on Aerodrome pools
  - Claim and process rewards
  - Manage collateral ratios

#### 2. Aerodrome-Relayer Portfolio
- **Purpose**: Manage positions for users without active loans
- **Features**:
  - Lock veAERO tokens
  - Vote on Aerodrome pools
  - Claim and process rewards
  - Swap rewards to increase collateral
  - No loan management functionality

### Account Creation

Portfolio accounts are created through the factory:

```solidity
// Create a new portfolio account for a user
address portfolio = portfolioFactory.createAccount(user);

// The account address is deterministic based on the user address
// Same user address = same portfolio account address (via CREATE2)
```

## Key Components

### FortyAcresPortfolioAccount
- Diamond proxy contract that references facets from the FacetRegistry
- Implements `multicall` for batching operations within a single account
- Uses fallback to delegate calls to appropriate facets

### FacetRegistry
- Centralized registry mapping function selectors to facet addresses
- Enables upgradeability without changing account addresses
- Versioned to track registry updates

### PortfolioFactory
- Deploys new portfolio accounts using CREATE2
- Tracks ownership (user → portfolio mapping)
- Registers accounts with PortfolioManager

### PortfolioManager
- Central coordinator for the entire system
- Deploys factories and facet registries
- Provides cross-account multicall functionality
- Tracks all portfolios across all factories

## Security Features

1. **Ownership Verification**: All multicall operations verify portfolio ownership
2. **Collateral Enforcement**: Automatic checks ensure positions remain healthy
3. **Isolated Accounts**: Single-use accounts limit exposure
4. **Deterministic Deployment**: Predictable addresses reduce deployment risks
5. **Facet Registry**: Centralized facet management enables secure upgrades

## Workflow Example

1. **User creates portfolio account** via factory
2. **User deposits collateral** (e.g., veAERO tokens) into the account
3. **User requests loan** through the account's lending facet
4. **User votes on pools** using the voting facet
5. **User claims rewards** and processes them
6. **All operations** can be batched via PortfolioManager's multicall
7. **Collateral is enforced** automatically after each multicall


