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
     * @notice Pays an amount towards a loan
     * @param tokenId The ID of the loan (NFT).
     * @param amount The amount to pay. If 0, the full loan balance is paid.
     */
    function pay(uint256 tokenId, uint256 amount) external;
    
    /**
     * @notice Transfers a token within the 40 Acres ecosystem
     * @param toContract The destination loan contract address
     * @param tokenId The ID of the token being transferred
     * @param amount The amount to borrow in the new contract
     * @param tradeData The trade data for swapping tokens (if needed)
     * @return success A boolean indicating whether the transfer was successful
     */
    function transferWithin40Acres(
        address toContract,
        uint256 tokenId,
        uint256 amount,
        bytes calldata tradeData
    ) external returns (bool success);
    
    /**
     * @notice Requests a loan for a user by locking a token as collateral
     * @param user The address of the user requesting the loan
     * @param tokenId The ID of the token being used as collateral
     * @param amount The amount of the loan requested. If 0, no initial loan amount is added
     * @param zeroBalanceOption The option specifying how zero balance scenarios should be handled
     * @param increasePercentage The percentage of the rewards to reinvest into venft
     * @param preferredToken The preferred token for receiving rewards or payments
     * @param topUp Indicates whether to top up the loan amount automatically
     * @param optInCommunityRewards Indicates whether to opt in to community rewards
     */
    function requestLoanForUser(
        address user,
        uint256 tokenId,
        uint256 amount,
        ZeroBalanceOption zeroBalanceOption,
        uint256 increasePercentage,
        address preferredToken,
        bool topUp,
        bool optInCommunityRewards
    ) external;
}
