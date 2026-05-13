---
"@40-acres/contracts": minor
---

Ship `bridgeFacetAbi` in the package. BridgeFacet exposes `bridge(amount, maxFee)` for direct USDC CCTP bridging and `swapMultiple(RouteParams[]) returns (uint256)` for batched non-USDC → USDC conversion (callers follow up with `bridge(...)` to send the accumulated USDC). `swapMultiple` mirrors `swapToRewardsTokenMultiple`: skips entries whose input is already USDC or is blocked by the `_isSwapAllowed` hook, and swallows per-route reverts as `SwapFailed(uint256 inputAmount, address indexed inputToken, address outputToken, address indexed owner)` events without aborting the batch.
