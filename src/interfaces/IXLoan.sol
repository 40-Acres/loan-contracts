// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IXLoan {
    enum ZeroBalanceOption {
        DoNothing,
        InvestToVault,
        PayToOwner
    }

    function activeAssets() external view returns (uint256);
    function lastEpochReward() external view returns (uint256);
    function requestLoan(uint256 amount,ZeroBalanceOption zeroBalanceOption,uint256 increasePercentage,address preferredToken,bool topUp) external;
    function setIncreasePercentage(uint256 increasePercentage) external;
    function claimCollateral() external;
    function getRewardsRate() external view returns (uint256);
    function owner() external view returns (address);
    function _asset() external view returns (address);
    function _ve() external view returns (address);
    function getLoanDetails(address) external view returns (uint256 balance, address borrower);
    function pay(uint256 amount) external;
    function setBorrower(address borrower) external;
    function increaseLoan(uint256 amount) external;
    
    
    /**
     * @notice Finalizes a marketplace purchase by assigning the borrower to the buyer
     * @dev Must only be callable by the configured marketplace/diamond/router
     * @param buyer The address of the buyer
     * @param expectedSeller The expected seller recorded on the listing
     */
    function finalizeMarketPurchase(address buyer, address expectedSeller) external;
    function finalizeLBOPurchase(address buyer) external;
    function finalizeOfferPurchase(address buyer, address expectedSeller, uint256 offerId) external;
    
    /**
     * @notice Calculates the maximum loan amount for a token
     * @return maxLoan The maximum loan amount
     * @return maxLoanIgnoreSupply The maximum loan amount ignoring supply constraints
     */
    function getMaxLoan() external view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply);

    /**
     * @notice Gets the vault address
     * @return vault The vault address
     */
    function _vault() external view returns (address);
    
    function vote() external returns (bool);
    function userVote(address[] calldata pools, uint256[] calldata weights) external;
    function claim(address[] calldata fees, address[][] calldata tokens, bytes calldata tradeData, uint256[2] calldata allocations) external returns (uint256);
}
