// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


interface ILoan {
    // ZeroBalanceOption enum to handle different scenarios when the loan balance is zero
    enum ZeroBalanceOption {
        DoNothing, // do nothing when the balance is zero
        InvestToVault, // invest the balance to the vault
        PayToOwner // pay the balance to the owner
    }


    function activeAssets() external view returns (uint256);
    function lastEpochReward() external view returns (uint256);
    function requestLoan(uint256 tokenId,uint256 amount,ZeroBalanceOption zeroBalanceOption,uint256 increasePercentage,address preferredToken,bool topUp, bool optInCommunityRewards) external;
    function requestLoan(uint256 tokenId,uint256 amount,ZeroBalanceOption zeroBalanceOption,uint256 increasePercentage,address preferredToken,bool topUp) external;
    function setIncreasePercentage(uint256 tokenId,uint256 increasePercentage) external;
    function claimCollateral(uint256 tokenId) external;

    function getRewardsRate() external view returns (uint256);

    function owner() external view returns (address);
    
    /**
     * @notice Gets the loan details for a specific token ID.
     * @param tokenId The ID of the loan (NFT).
     * @return balance The current balance of the loan.
     * @return borrower The address of the borrower.
     */
    function getLoanDetails(uint256 tokenId) external view returns (uint256 balance, address borrower);
    
    /**
     * @notice Gets the loan weight for a specific token ID.
     * @param tokenId The ID of the loan (NFT).
     * @return weight The weight of the loan.
     */
    function getLoanWeight(uint256 tokenId) external view returns (uint256 weight);
    
    /**
     * @notice Pays an amount towards a loan
     * @param tokenId The ID of the loan (NFT).
     * @param amount The amount to pay. If 0, the full loan balance is paid.
     */
    function pay(uint256 tokenId, uint256 amount) external;
    
    
    /**
     * @notice Finalizes a marketplace purchase by assigning the borrower to the buyer
     * @dev Must only be callable by the configured marketplace/diamond/router
     * @param tokenId The ID of the loan (NFT)
     * @param buyer The address of the buyer
     * @param expectedSeller The expected seller recorded on the listing
     */
    function finalizeMarketPurchase(uint256 tokenId, address buyer, address expectedSeller) external;

    /**
     * @notice Finalizes LBO purchase by transferring borrower from market to the buyer
     * @dev Must only be callable by the configured marketplace/diamond/router
     * @param tokenId The ID of the loan (NFT)
     * @param buyer The address of the buyer
     */
    function finalizeLBOPurchase(uint256 tokenId, address buyer) external;

    /**
     * @notice Finalizes an offer-based purchase by assigning the borrower to the buyer
     * @dev Must only be callable by the configured marketplace/diamond/router
     * @param tokenId The ID of the loan (NFT)
     * @param buyer The address of the buyer (offer creator)
     * @param expectedSeller The expected seller (current borrower)
     * @param offerId The accepted offer identifier
     */
    function finalizeOfferPurchase(uint256 tokenId, address buyer, address expectedSeller, uint256 offerId) external;
    
    /**
     * @notice Calculates the maximum loan amount for a token
     * @param tokenId The ID of the token
     * @return maxLoan The maximum loan amount
     * @return maxLoanIgnoreSupply The maximum loan amount ignoring supply constraints
     */
    function getMaxLoan(uint256 tokenId) external view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply);
    
}
