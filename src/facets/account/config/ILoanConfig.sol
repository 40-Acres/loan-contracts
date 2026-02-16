// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface ILoanConfig {
    function getActiveRates() external view returns (uint256 lenderPremium, uint256 treasuryFee);
    function getRewardsRate() external view returns (uint256);
    function getMultiplier() external view returns (uint256);
    function getLenderPremium() external view returns (uint256);
    function getTreasuryFee() external view returns (uint256);
    function getZeroBalanceFee() external view returns (uint256);
    function setRewardsRate(uint256 rewardsRate) external;
    function setMultiplier(uint256 multiplier) external;
    function setLenderPremium(uint256 lenderPremium) external;
    function setTreasuryFee(uint256 treasuryFee) external;
    function setZeroBalanceFee(uint256 zeroBalanceFee) external;
}
