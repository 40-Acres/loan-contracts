---
"@40-acres/contracts": patch
---

ERC4626 and YieldBasis collateral managers (regular + Dynamic): cap borrow capacity at collateral cost basis. `getMaxLoan` now prices collateral at `min(depositedAssetValue, currentValue)` so appreciation is reserved for yield harvesting and is always fully harvestable for lenders, instead of being borrowable. Internal change; ABI unchanged.
