# LoanV2 MarketV1 Upgrade - Documentation for Auditors

The focus of the audit is to ensure that new market settlement and flash loan functionality added to `src/LoanV2.sol` is correctly implemented and does not introduce any new vulnerabilities.

## Changes to LoanV2

The LoanV2 contract has been updated to support market settlement functionality and flash loans. Below is a detailed analysis of the new functions and their security assertions:

### New Market Settlement Functions

#### `_setBorrower(uint256 tokenId, address newBorrower)`
- **Purpose**: Internal function to update the borrower of a loan
- **Security Assertions**:
  - Reverts with `ZeroAddress` if newBorrower is address(0)
  - Reverts with `Unauthorized` if caller is neither current borrower nor market diamond
  - Emits `BorrowerChanged` event with previous and new borrower addresses

#### `finalizeMarketPurchase(uint256 tokenId, address buyer, address expectedSeller)`
- **Purpose**: Finalizes a direct market purchase of a loan
- **Security Assertions**:
  - Reverts with `ZeroAddress` if buyer is address(0)
  - Reverts with `InvalidListing` if listing is invalid or expired
  - Reverts with `SellerMismatch` if loan borrower or listing owner doesn't match expected seller
  - Reverts with `LoanNotPaidOff` if loan balance is not zero
  - Only callable by market diamond (via `onlyMarketDiamond` modifier)

#### `finalizeOfferPurchase(uint256 tokenId, address buyer, address expectedSeller, uint256 offerId)`
- **Purpose**: Finalizes an offer-based purchase of a loan
- **Security Assertions**:
  - Reverts with `ZeroAddress` if buyer is address(0)
  - Reverts with `InvalidOffer` if offer is invalid or expired
  - Reverts with `CreatorMismatch` if offer creator doesn't match buyer
  - Reverts with `SellerMismatch` if loan borrower doesn't match expected seller
  - Reverts with `LoanNotPaidOff` if loan balance is not zero
  - Only callable by market diamond

#### `finalizeLBOPurchase(uint256 tokenId, address buyer)`
- **Purpose**: Finalizes a leveraged buyout (LBO) purchase of a loan
- **Security Assertions**:
  - Reverts with `ZeroAddress` if buyer is address(0)
  - Reverts with `Unauthorized` if market diamond is not current borrower
  - Uses `require` to ensure loan balance equals outstanding capital plus unpaid fees
  - Only callable by market diamond

### New Flash Loan Functions

#### `maxFlashLoan(address token)`
- **Purpose**: Returns maximum flash loan amount available
- **Security Assertion**: Returns 0 for any token other than the contract's asset

#### `flashFee(address token, uint256 amount)`
- **Purpose**: Calculates flash loan fee
- **Security Assertions**:
  - Reverts with `UnsupportedToken` for non-asset tokens
  - Charges 0% fee for market diamond (LBO operations)
  - Uses `getFlashLoanFee()` for other callers (basis points calculation)

#### `flashLoan(IFlashLoanReceiver receiver, address token, uint256 amount, bytes calldata data)`
- **Purpose**: Executes a flash loan
- **Security Assertions**:
  - Reverts with `FlashLoansPaused` if flash loans are paused
  - Reverts with `InvalidFlashLoanReceiver` if receiver is not market diamond
  - Reverts with `UnsupportedToken` for non-asset tokens
  - Reverts with `ExceededMaxLoan` if amount exceeds available liquidity
  - Reverts with `InvalidFlashLoanReceiver` if callback doesn't return success
  - Reverts with `InsufficientAllowance` if receiver lacks sufficient allowance
  - Uses `nonReentrant` modifier to prevent reentrancy attacks
  - Only callable by market diamond

### New Storage Parameters in LoanStorage

The following storage parameters were added to LoanStorage.sol to support the new market settlement and flash loan functionality:

- **_marketDiamond**: Address of the market diamond contract authorized for borrower finalization. This parameter is critical for the `onlyMarketDiamond` modifier and market settlement functions like `finalizeMarketPurchase`, `finalizeOfferPurchase`, and `finalizeLBOPurchase`.

- **_flashLoanFee**: Basis points value (e.g., 50 = 0.5%) representing the flash loan fee percentage. Used in the `flashFee` function to calculate fees for non-market diamond callers.

- **_FlashLoanPaused**: Boolean flag that can be set by the owner to pause all flash loan functionality during emergencies. Checked in the `flashLoan` function via `getFlashLoanPaused()`.

These storage parameters enable the new functionality while maintaining upgrade safety through the ERC-7201 storage pattern.

### Additional Security Enhancements

- **New Error Codes**: Added specific error codes for better failure diagnosis:
  - Flash loan errors: `UnsupportedToken`, `ExceededMaxLoan`, `InvalidFlashLoanReceiver`
  - General validation errors: `InvalidOffer`, `InvalidListing`, `Unauthorized`, `LoanNotPaidOff`, `SellerMismatch`, `CreatorMismatch`, `FlashLoansPaused`, `InsufficientAllowance`, `MarketNotConfigured`, `ZeroAddress`
  
- **New Modifier**: `onlyMarketDiamond()` ensures market-related functions can only be called by the market diamond contract

- **New Events**: Added `BorrowerChanged` and `FlashLoan` events for better transaction transparency
