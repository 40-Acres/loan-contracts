---
"@40-acres/contracts": minor
---

Add `walletFacetAbi` (per-user account utilities: `receiveERC20`,
`transferERC20`, `transferNFT`, `withdrawERC20`, `swap`,
`enforceCollateralRequirements`, `onERC721Received`).

Frontend can now consume this ABI directly via
`import { walletFacetAbi } from '@40-acres/contracts'` instead of the
hand-typed `WALLET_FACET_ABI` in `src/abi/wallet_facet_abi.ts`.
