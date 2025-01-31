// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.27;

interface IRateCalculator {
    function setInterestRate(uint256 _protocolFee, uint256 _lenderPremium) external;
    function getInterestRate() external view returns (uint256, uint256);
    function setRewardsRate(uint256 _rewardsRate) external;
    function getRewardsRate() external view returns (uint256);
    function confirm() external;
    function getZeroBalanceFee() external view returns (uint256);
}