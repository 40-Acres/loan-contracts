// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title Interface for CommunityRewards contract
interface ICommunityRewards {
    error InvalidReward();
    error NotAuthorized();
    error ZeroAmount();

    event Deposit(address indexed from, uint256 amount);
    event Withdraw(address indexed from, uint256 amount);
    event NotifyReward(address indexed from, address indexed reward, uint256 indexed epoch, uint256 amount);
    event ClaimRewards(address indexed from, address indexed reward, uint256 amount);

    function transfer(address _recipient, uint256 _amount) external returns (bool);

    function notifyRewardAmount(address _token, uint256 _amount) external;

    function getPriorBalanceIndex(address _owner, uint256 _timestamp) external view returns (uint256);

    function getPriorSupplyIndex(uint256 _timestamp) external view returns (uint256);

    function rewardsListLength() external view returns (uint256);

    function earned(address _token, address _owner) external returns (uint256);

    function deposit(uint256 _tokenId, uint256 _amount, address _owner) external;

    function getReward(address[] memory _tokens) external;

    function getUserFlightSchoolAllocation(address _owner, uint256 _tokenId, uint256 _epoch) external;

    function notifyFlightBonus(uint256 flight, uint256 amount) external;

    function claimFlightBonus(address owner, uint256 month) external;
}