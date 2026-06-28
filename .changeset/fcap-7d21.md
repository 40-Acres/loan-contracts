---
"@40-acres/contracts": minor
---

DynamicFeesVault + LendingVault: rework the same-block guards. (1) Add `borrowableTotalAssets()` (= `totalAssets()` minus assets deposited in the current block); the Dynamic / YieldBasis / ERC4626 collateral managers now read it for the vault-supply term in `getMaxLoan`, so a same-block (flash) deposit can no longer transiently raise a borrower's max loan above the utilization cap. Pattern-A markets (`CollateralManager` / `HydrexCollateralManager`, legacy `Vault.sol`-backed) are out of scope and unchanged. (2) Remove the prior same-block lender share-pinning guard: same-block deposit/mint -> withdraw/redeem is allowed again (`maxWithdraw`/`maxRedeem` revert to liquid-capped `balanceOf`). New public view added; no existing ABI removed or changed.
