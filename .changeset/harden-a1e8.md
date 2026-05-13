---
"@40-acres/contracts": patch
---

Harden rewards distribution config against malicious user-supplied targets.

- `SwapConfig`: add `approvedVaults` and `approvedOutputTokens` allowlists. New owner-only setters `setApprovedVault` / `setApprovedOutputToken`, view accessors `isApprovedVault` / `isApprovedOutputToken`, and EnumerableSet getters (`getApprovedVaultsList`, `getApprovedVaultsListLength`, `getApprovedVaultAtIndex`, plus the matching OutputToken trio). Storage extended via append-only fields in the existing `keccak256("storage.SwapConfig")` slot — UUPS-safe.
- `RewardsConfigFacet`: constructor signature changed from `(address portfolioFactory)` to `(address portfolioFactory, address swapConfig)`. All deploy scripts and test setups updated to pass the per-network `SwapConfig` address.
- `RewardsConfigFacet.setVaultForInvesting(vault)`: now reverts with `"Vault not approved"` for any vault not registered in `SwapConfig.approvedVaults` (no zero-address bypass).
- `RewardsConfigFacet.setZeroBalanceDistribution(entries)` and `setActiveBalanceDistribution(entry)`: now reject `InvestToVault` entries whose target is not in `approvedVaults` (`"InvestToVault target not approved"`), and `PayToRecipient` entries whose non-zero `outputToken` is not in `approvedOutputTokens` (`"PayToRecipient outputToken not approved"`). Existing `PayDebt` factory validation unchanged.

Operational note: before this upgrade goes live on a network, the `SwapConfig` owner must seed `approvedVaults` and `approvedOutputTokens` with the protocol's intended targets. Configs saved before the upgrade keep working (validation runs only at config-set time); new `setVaultForInvesting` / distribution writes will revert until the lists are populated.
