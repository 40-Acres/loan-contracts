## 40 Acres Loan Contracts

40 Acres provides utility for veNFT holders including instant access to loans based on their veNFTs future revenue. Each week the veNFT rewards are used to repay the loan automatically. Additionally, veNFTs can be listed on the marketplace and purchased with or without outstanding loans. Supports aggregation of external markets and leveraged buyouts of veNFTs using flash loans.

## Contract Architecture

The system is built using upgradeable contracts with the following key components:

- **Vault**: Holds loan assets (typically USDC) and manages asset accounting
- **Loan**: Core loan logic with rewards handling and repayment mechanics
- **Market**: Enables trading of veNFTs with or without outstanding loans
- **Voter**: Interfaces with external voting systems for protocol governance
- **Swapper**: Handles token swaps for rewards distribution
- **RateStorage**: Stores protocol fee rates and other parameters

Contracts use UUPS upgradeability pattern and inherit from OpenZeppelin's upgradeable contracts.

## Contracts

- [LoanV2](src/LoanV2.sol) - Main loan contract with rewards rate-based lending and manages the veNFTs.
- [LoanV2Native](src/LoanV2Native.sol) - Inherits LoanV2 but overrides the USDC oracle since do not need to verify usdc price
- [Vault](src/Vault.sol) - Base vault contract implementing ERC4626 to hold the loan assets (typically USDC) and use the veNFT rewards to repay the loan automatically.
- [VaultV2](src/VaultV2.sol) - Upgradeable version of the vault
- [Voter](src/interfaces/IVoter.sol) - Interface for external voting systems
- [Swapper](src/Swapper.sol) - Token swapping logic for rewards
- [RateStorage](src/RateStorage.sol) - Storage for protocol fee rates
- [ReentrancyGuard](src/ReentrancyGuard.sol) - Reentrancy protection for contracts
- [VeloLoan](src/VeloLoan.sol) - Velo-specific loan implementation
- [VeloLoanV2](src/VeloLoanV2.sol) - Upgradeable Velo loan contract
- [VeloLoanV2Native](src/VeloLoanV2Native.sol) - Native token version of VeloLoanV2

### Market V1 Diamond Implementation

Storage uses ERC‑7201 layouts in `src/libraries/storage/MarketStorage.sol`.

**Core facets:** `DiamondCutFacet`, `DiamondLoupeFacet`, `OwnershipFacet`.

**Market facets:**
- `MarketRouterFacet` (single entry; routes to wallet/loan/external flows)
- `MarketConfigFacet` (init/admin/pause/allowlists; expected `loanAsset`)
- `MarketViewFacet` (readonly)
- `MarketListingsWalletFacet` (wallet‑held listings/takes)
- `MarketListingsLoanFacet` (LoanV2/LoanV3‑held listings/takes; enforces payoff before transfer)
- `MarketOfferFacet` (offers)
- `MarketMatchingFacet` (single entry; routes to wallet/loan/external flows)
- Adapter facets (per external market). Example implemented: `src/facets/market/VexyAdapterFacet.sol`.

**Internal libraries**
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


## Testing

### Test Files
- [Loan.t.sol](test/Loan.t.sol) - Loan contract tests
- [Vault.t.sol](test/Vault.t.sol) - Vault contract tests
- [Swapper.t.sol](test/Swapper.t.sol) - Swapper contract tests
- [PharaohLoan.t.sol](test/PharaohLoan.t.sol) - Pharaoh loan implementation tests
- [test/market/](test/market/) - Market contract tests

### Testing Commands
- Run all tests: `forge test`
- Run specific test: `forge test -m testFunctionName`
- Coverage: `forge coverage`

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
