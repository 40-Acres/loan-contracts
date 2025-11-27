## Portfolio Account Facets

Claiming Flow
1. Claim Fees (permissionless)
   1. All of the users tokens will be help within their account
2. Swap (permissioned)
   1. Swap tokens help within the account to the desired reward token (USDC, or preferred token), and the lockedAsset if they want to increase their collateral
3. Bridge (when applicable) (permissioned)
   1. Bridge asset token to the main chain
4. Process Rewards (permissioned)
   1. Use the resulting tokens to process their rewards 
   2. handleClaim on the original LoanV2 contract
   3. Tokens will be sent to the user from the Loan contract

These can be done in one call from designated wallets using `multicall`, or done in multiple transactions
