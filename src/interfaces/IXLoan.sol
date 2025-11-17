// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
    function getRewardsRate() external view returns (uint256);
    function _vaultAsset() external view returns (IERC20);
    function _lockedAsset() external view returns (IERC20);
    function getLoanDetails(address) external view returns (uint256 balance, address borrower);
    function pay(address borrower, uint256 amount) external;
    function increaseLoan(uint256 amount) external;
    
    /**
     * @notice Calculates the maximum loan amount for a token
     * @param borrower The address of the borrower
     * @return maxLoan The maximum loan amount
     * @return maxLoanIgnoreSupply The maximum loan amount ignoring supply constraints
     */
    function getMaxLoan(address borrower) external view returns (uint256 maxLoan, uint256 maxLoanIgnoreSupply);

    /**
     * @notice Gets the vault address
     * @return vault The vault address
     */
    function _vault() external view returns (address);
    
    function vote(address user) external returns (bool);
    function userVote(address[] calldata pools, uint256[] calldata weights) external;
    function claim(address[] calldata fees, address[][] calldata tokens, bytes calldata tradeData, uint256 totalRewards) external returns (uint256);
    function confirmClaimCollateral(address lockedAsset) external;
    function setZeroBalanceOption(ZeroBalanceOption zeroBalanceOption) external;
    function setTopUp(bool topUp) external;
    function setPreferredToken(address preferredToken) external;
    function getPreferredToken(address user) external view returns (address);
}
