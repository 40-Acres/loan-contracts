// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILoan {
    enum ZeroBalanceOption {
        DoNothing,
        InvestToVault,
        PayToOwner
    }

    function activeAssets() external view returns (uint256);
    function lastEpochReward() external view returns (uint256);
    function requestLoan(uint256 tokenId,uint256 amount,ZeroBalanceOption zeroBalanceOption,uint256 increasePercentage,address preferredToken,bool topUp, bool optInCommunityRewards) external;
    function setIncreasePercentage(uint256 tokenId,uint256 increasePercentage) external;
    function claimCollateral(uint256 tokenId) external;
    function getRewardsRate() external view returns (uint256);
    function getMultiplier() external view returns (uint256);
    function owner() external view returns (address);
function _asset() external view returns (address);
    function _ve() external view returns (address);
    function getLoanDetails(uint256 tokenId) external view returns (uint256 balance, address borrower);
    function getLoanWeight(uint256 tokenId) external view returns (uint256 weight);
    function pay(uint256 tokenId, uint256 amount) external;
    function setBorrower(uint256 tokenId, address borrower) external;
    function increaseLoan(uint256 tokenId, uint256 amount) external;    
    function setTopUpAndPreferredToken(uint256 tokenId, bool topUp, address preferredToken) external;
    function setZeroBalanceOption(uint256 tokenId, ZeroBalanceOption zeroBalanceOption) external;

    /**
     * @notice Finalizes a marketplace purchase by assigning the borrower to the buyer
     * @dev Must only be callable by the configured marketplace/diamond/router
     * @param tokenId The ID of the loan (NFT)
     * @param buyer The address of the buyer
     * @param expectedSeller The expected seller recorded on the listing
     */
    function finalizeMarketPurchase(uint256 tokenId, address buyer, address expectedSeller) external;
    function finalizeLBOPurchase(uint256 tokenId, address buyer) external;
    function finalizeOfferPurchase(uint256 tokenId, address buyer, address expectedSeller, uint256 offerId) external;
    
    /**
     * @notice Calculates the maximum loan amount for a token
     * @param tokenId The ID of the token
     * @return maxLoan The maximum loan amount
     * @return maxLoanIgnoreSupply The maximum loan amount ignoring supply constraints
     */
    function getMaxLoan(uint256 tokenId) external view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply);

    /**
     * @notice Gets the vault address
     * @return vault The vault address
     */
    function _vault() external view returns (address);
    
    function transferWithin40Acres(
        address toContract,
        uint256 tokenId,
        uint256 borrowAmount,
        bytes calldata tradeData
    ) external returns (bool success);
    function vote(uint256 tokenId) external returns (bool);
    function userVote(uint256[] calldata tokenIds, address[] calldata pools, uint256[] calldata weights) external;
    function claim(uint256 tokenId, address[] calldata fees, address[][] calldata tokens, bytes calldata tradeData, uint256[2] calldata allocations) external returns (uint256);
    function handleZeroBalanceLoanPortfolioAccount(uint256 tokenId, address asset, uint256 totalRewards, uint256 rewardsPaidtoOwner, uint256 rewardsInvested, uint256 protocolFee) external;

    function borrowFromPortfolio(uint256 amount) external;
    function payFromPortfolio(uint256 balanceToPay) external;
}
