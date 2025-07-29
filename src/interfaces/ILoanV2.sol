// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IFlashLoanReceiver} from "./IFlashLoanReceiver.sol";

interface ILoanV2 {
    // ZeroBalanceOption enum to handle different scenarios when the loan balance is zero
    enum ZeroBalanceOption {
        DoNothing, // do nothing when the balance is zero
        InvestToVault, // invest the balance to the vault
        PayToOwner // pay the balance to the owner
    }

    // LoanInfo struct to store details about each loan
    struct LoanInfo {
        uint256 tokenId;
        uint256 balance;
        address borrower;
        uint256 timestamp;
        uint256 outstandingCapital;
        ZeroBalanceOption zeroBalanceOption;
        address[] pools; // deprecated
        uint256 voteTimestamp;
        uint256 claimTimestamp;
        uint256 weight;
        uint256 unpaidFees; // unpaid fees for the loan
        address preferredToken; // preferred token to receive for zero balance option
        uint256 increasePercentage; // Percentage of the rewards to increase each lock
        bool topUp; // automatically tops up loan balance after rewards are claimed
        bool optInCommunityRewards; // opt in to community rewards
    }

    // Events
    event CollateralAdded(uint256 tokenId, address owner, ZeroBalanceOption option);
    event CollateralWithdrawn(uint256 tokenId, address owner);
    event FundsBorrowed(uint256 tokenId, address owner, uint256 amount);
    event RewardsReceived(uint256 epoch, uint256 amount, address borrower, uint256 tokenId);
    event LoanPaid(uint256 tokenId, address borrower, uint256 amount, uint256 epoch, bool isManual);
    event RewardsInvested(uint256 epoch, uint256 amount, address borrower, uint256 tokenId);
    event RewardsClaimed(uint256 epoch, uint256 amount, address borrower, uint256 tokenId, address token);
    event RewardsPaidtoOwner(uint256 epoch, uint256 amount, address borrower, uint256 tokenId, address token);
    event ProtocolFeePaid(uint256 epoch, uint256 amount, address borrower, uint256 tokenId, address token);
    event VeNftIncreased(uint256 epoch, address indexed user, uint256 indexed tokenId, uint256 amount, uint256 indexed fromToken);
    event FlashLoan(address indexed receiver, address indexed initiator, address indexed token, uint256 amount, uint256 fee);

    // Errors
    error UnsupportedToken(address token);
    error ExceededMaxLoan(uint256 maxLoan);
    error InvalidFlashLoanReceiver(address receiver);

    // Main loan functions
    function requestLoan(
        uint256 tokenId,
        uint256 amount,
        ZeroBalanceOption zeroBalanceOption,
        uint256 increasePercentage,
        address preferredToken,
        bool topUp,
        bool optInCommunityRewards
    ) external;

    function increaseLoan(uint256 tokenId, uint256 amount) external;
    function pay(uint256 tokenId, uint256 amount) external;
    function payMultiple(uint256[] memory tokenIds) external;
    function claimCollateral(uint256 tokenId) external;

    // Rewards and claiming
    function incentivizeVault(uint256 amount) external;
    function claim(
        uint256 tokenId, 
        address[] calldata fees, 
        address[][] calldata tokens, 
        bytes calldata tradeData, 
        uint256[2] calldata allocations
    ) external returns (uint256);

    function increaseAmount(uint256 tokenId, uint256 amount) external;

    // View functions
    function getMaxLoan(uint256 tokenId) external view returns (uint256, uint256);
    function getLoanDetails(uint256 tokenId) external view returns (uint256 balance, address borrower);
    function activeAssets() external view returns (uint256);
    function lastEpochReward() external view returns (uint256);
    function odosRouter() external pure returns (address);

    // Rate functions
    function getZeroBalanceFee() external view returns (uint256);
    function getRewardsRate() external view returns (uint256);
    function getLenderPremium() external view returns (uint256);
    function getProtocolFee() external view returns (uint256);

    // Owner functions
    function mergeIntoManagedNft(uint256 tokenId) external;
    function setManagedNft(uint256 tokenId) external;
    function setDefaultPools(address[] calldata pools, uint256[] calldata weights) external;
    function setMultiplier(uint256 multiplier) external;
    function setApprovedPools(address[] calldata pools, bool enable) external;
    function rescueERC20(address token, uint256 amount) external;
    function setFlashLoanFee(uint256 fee) external;
    function transferLoanOwnership(uint256 tokenId, address newOwner) external;
    function setApprovedMarketContracts(address[] calldata marketContracts, bool enable) external;

    // User configuration functions
    function setZeroBalanceOption(uint256 tokenId, ZeroBalanceOption option) external;
    function setTopUp(uint256 tokenId, bool enable) external;
    function setPreferredToken(uint256 tokenId, address preferredToken) external;
    function setOptInCommunityRewards(uint256[] calldata tokenIds, bool optIn) external;
    function setIncreasePercentage(uint256 tokenId, uint256 increasePercentage) external;
    function setPayoffToken(uint256 tokenId, bool enable) external;

    // Voting functions
    function userVote(
        uint256[] calldata tokenIds,
        address[] calldata pools,
        uint256[] calldata weights
    ) external;
    function vote(uint256 tokenId) external returns (bool);
    function merge(uint256 from, uint256 to) external;

    // Flash loan functions
    function maxFlashLoan(address token) external view returns (uint256);
    function flashFee(address token, uint256 amount) external view returns (uint256);
    function flashLoan(
        IFlashLoanReceiver receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool);

    // Public state variables (getters)
    function _vault() external view returns (address);
    function _outstandingCapital() external view returns (uint256);
    function _multiplier() external view returns (uint256);
    function FLASH_LOAN_FEE() external view returns (uint256);
    function CALLBACK_SUCCESS() external view returns (bytes32);
    function _loanDetails(uint256) external view returns (
        uint256 tokenId,
        uint256 balance,
        address borrower,
        uint256 timestamp,
        uint256 outstandingCapital,
        ZeroBalanceOption zeroBalanceOption,
        uint256 voteTimestamp,
        uint256 claimTimestamp,
        uint256 weight,
        uint256 unpaidFees,
        address preferredToken,
        uint256 increasePercentage,
        bool topUp,
        bool optInCommunityRewards
    );
    function _approvedPools(address) external view returns (bool);
    function _rewardsPerEpoch(uint256) external view returns (uint256);
    function _defaultPools(uint256) external view returns (address);
    function _defaultWeights(uint256) external view returns (uint256);
    function _defaultPoolChangeTime() external view returns (uint256);
} 