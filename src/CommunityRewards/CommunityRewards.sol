// SPDX-License-Identifier: BUSL-1.1

// Portions of this contract are adapted from Velodrome's Reward.sol
// Source: https://github.com/velodrome-finance/contracts/blob/a2548b1d91f3312acb9e4f317d8149d723d78f00/contracts/rewards/Reward.sol
// Commit: a2548b1d91f3312acb9e4f317d8149d723d78f00
// Originally licensed under the MIT License.
// Copyright (c) Velodrome Finance

pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IReward} from "../interfaces/IReward.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ILoan} from "../interfaces/ILoan.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { console } from "forge-std/console.sol";

interface IOwnable {
    function owner() external view returns (address);
}

/* 
 * @title CommunityRewards
 * @notice A contract for managing community rewards distribution.
 * @dev This contract is upgradeable and uses OpenZeppelin's upgradeable libraries.
 */
contract CommunityRewards is Initializable, UUPSUpgradeable, ERC20Upgradeable, ReentrancyGuardUpgradeable  {
    using SafeERC20 for IERC20;

    /* 
     * @notice Error thrown when an invalid reward token is provided.
     */
    error InvalidReward();

    /* 
     * @notice Error thrown when an unauthorized action is attempted.
     */
    error NotAuthorized();

    /* 
     * @notice Error thrown when a zero amount is provided where non-zero is required.
     */
    error ZeroAmount();

    /* 
     * @notice Emitted when a deposit is made.
     * @param from The address making the deposit.
     * @param amount The amount deposited.
     */
    event Deposit(address indexed from, uint256 amount);

    /* 
     * @notice Emitted when a withdrawal is made.
     * @param from The address making the withdrawal.
     * @param amount The amount withdrawn.
     */
    event Withdraw(address indexed from, uint256 amount);

    /* 
     * @notice Emitted when a reward is notified.
     * @param from The address notifying the reward.
     * @param reward The reward token address.
     * @param epoch The epoch for which the reward is notified.
     * @param amount The amount of the reward.
     */
    event NotifyReward(
        address indexed from,
        address indexed reward,
        uint256 indexed epoch,
        uint256 amount
    );

    /* 
     * @notice Emitted when rewards are claimed.
     * @param from The address claiming the rewards.
     * @param reward The reward token address.
     * @param amount The amount of rewards claimed.
     */
    event ClaimRewards(
        address indexed from,
        address indexed reward,
        uint256 amount
    );

    /* 
     * @notice Emitted when a flight bonus is notified.
     * @param flight The flight epoch.
     * @param amount The bonus amount.
     */
    event NotifyFlightBonus(uint256 indexed flight, uint256 amount);

    /* 
     * @notice Emitted when a flight bonus is claimed.
     * @param from The address claiming the bonus.
     * @param flight The flight epoch.
     * @param amount The bonus amount claimed.
     */
    event ClaimFlightBonus(address indexed from, uint256 indexed flight, uint256 amount);

    /* 
     * @notice The duration of each reward epoch.
     */
    uint256 public constant DURATION = 7 days;

    /* 
     * @notice The address authorized to call certain functions.
     */
    address public authorized;

    /* 
     * @notice Mapping of token rewards per epoch.
     */
    mapping(address => mapping(uint256 => uint256)) public tokenRewardsPerEpoch;

    /* 
     * @notice Mapping of claimed rewards per epoch.
     */
    mapping(address => mapping(address => mapping(uint256 => uint256)))
        public tokenClaimedPerEpoch;

    /* 
     * @notice Mapping of the last earned rewards for each token and owner.
     */
    mapping(address => mapping(address => uint256)) public lastEarn;

    /* 
     * @notice Mapping of the last notification timestamp for each token.
     */
    mapping(address => uint256) public lastNotify;

    /* 
     * @notice List of reward tokens.
     */
    address[] public rewards;

    /* 
     * @notice Mapping to check if an address is a reward token.
     */
    mapping(address => bool) public isReward;

    /* 
     * @notice The token ID of the community token.
     */
    uint256 public tokenId;

    /* 
     * @notice The threshold for rewards.
     */
    uint256 threshold;

    /* 
     * @notice Mapping of escrow token balances.
     */
    mapping(address => mapping(uint256 => mapping(uint256 => uint256)))
        public escrowTokenBalance;

    /* 
     * @notice Mapping of flight deposits for each account and epoch.
     */
    mapping(address => mapping(uint256 => uint256)) public flightDeposits;

    /* 
     * @notice Mapping of total flight deposits for each epoch.
     */
    mapping(uint256 => uint256) public totalFlightDeposits;

    /* 
     * @notice Mapping of flight bonuses for each epoch.
     */
    mapping(uint256 => uint256) public flightBonus;

    /* 
     * @notice Mapping of claimed flight bonuses for each account and epoch.
     */
    mapping(address => mapping(uint256 => uint256)) public flightBonusClaimed;

    /* 
     * @notice A checkpoint for marking balance.
     */
    struct Checkpoint {
        uint256 timestamp;
        uint256 _balances;
    }

    /*
     * @notice The address of the loan contract.
     */
    address public loanContract;

    /* 
     * @notice A checkpoint for marking supply.
     */
    struct SupplyCheckpoint {
        uint256 timestamp;
        uint256 supply;
    }

    /* 
     * @notice Mapping of balance checkpoints for each account.
     */
    mapping(address => mapping(uint256 => Checkpoint)) public checkpoints;

    /* 
     * @notice The number of checkpoints for each account.
     */
    mapping(address => uint256) public numCheckpoints;

    /* 
     * @notice Mapping of supply checkpoints for each token.
     */
    mapping(uint256 => SupplyCheckpoint) public supplyCheckpoints;

    /* 
     * @notice The number of supply checkpoints.
     */
    uint256 public supplyNumCheckpoints;

    /* 
     * @custom:oz-upgrades-unsafe-allow constructor
     */

     
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @dev This function is used to authorize upgrades to the contract.
     *      It restricts the upgradeability to only the contract owner.
     */
    function _authorizeUpgrade(address) internal override view {
        if (msg.sender != IOwnable(loanContract).owner()) revert NotAuthorized();
    }
    /* 
     * @notice Initializes the contract.
     * @param _loanContract The address of the loan contract.
     * @param _rewards The list of reward token addresses.
     * @param _threshold The threshold for rewards.
     * @param _tokenId The token ID of the community token.
     * @param _votingEscrow The address of the voting escrow contract.
     */
    function initialize(
        address _loanContract,
        address[] memory _rewards,
        uint256 _threshold,
        uint256 _tokenId,
        address _votingEscrow
    ) external initializer {
        __ERC20_init("40AcresCommunityRewards", "40A-Community-Rewards");
        __ReentrancyGuard_init();
        
        uint256 _length = _rewards.length;
        for (uint256 i; i < _length; i++) {
            if (_rewards[i] != address(0)) {
                isReward[_rewards[i]] = true;
                rewards.push(_rewards[i]);
            }
        }
        
        rewards.push(address(this)); // Add this contract to the list of rewards
        authorized = _loanContract;
        threshold = _threshold;
        IVotingEscrow(_votingEscrow).transferFrom(msg.sender, address(this), _tokenId);
        IVotingEscrow(_votingEscrow).approve(_loanContract, _tokenId);
        ILoan(_loanContract).requestLoan(_tokenId, 0, ILoan.ZeroBalanceOption.PayToOwner, 500, address(0), false, false);
        tokenId = _tokenId;
        loanContract = _loanContract;
    }
    
    /* 
     * @notice Transfers tokens to a recipient.
     * @param _recipient The address of the recipient.
     * @param _amount The amount to transfer.
     * @return True if the transfer is successful.
     */
    function transfer(
        address _recipient,
        uint256 _amount
    ) public override nonReentrant returns (bool) {
        address sender = _msgSender();

        _transfer(sender, _recipient, _amount);

        _writeCheckpoint(_recipient, balanceOf(_recipient));
        _writeCheckpoint(sender, balanceOf(sender));

        return true;
    }

    /* 
     * @notice Transfers tokens from a sender to a recipient.
     * @param _sender The address of the sender.
     * @param _recipient The address of the recipient.
     * @param _amount The amount to transfer.
     * @return True if the transfer is successful.
     */
    function transferFrom(
        address _sender,
        address _recipient,
        uint256 _amount
    ) public override nonReentrant returns (bool) {
        address msgSender = _msgSender();
        
        _spendAllowance(_sender, msgSender, _amount);
        _transfer(_sender, _recipient, _amount);
        
        _writeCheckpoint(_recipient, balanceOf(_recipient));
        _writeCheckpoint(_sender, balanceOf(_sender));
        
        return true;
    }

    

    /**
     * @notice Notifies the contract about a reward amount for a specific token
     * @dev This function adds rewards for the previous epoch, as rewards are distributed at the end of each epoch
     * @dev Only callable by the authorized address
     * @dev Protected against reentrancy attacks
     * @param _token The address of the reward token
     * @param _amount The amount of tokens to add as rewards
     */
    function notifyRewardAmount(
        address _token,
        uint256 _amount
    ) external nonReentrant {
        address sender = _msgSender();
        require(sender == authorized);
        if (_amount == 0) revert ZeroAmount();
        if (!isReward[_token]) revert InvalidReward();

        // we send the reward to the previous epoch since rewards are distributed at the end of the epoch
        uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp) -
            ProtocolTimeLibrary.WEEK;
        tokenRewardsPerEpoch[_token][epochStart] += _amount;

        lastNotify[_token] = block.timestamp;

        emit NotifyReward(sender, _token, epochStart, _amount);
    }

    /**
     * @notice Retrieves the index of the checkpoint valid at a specific timestamp for a given address
     * @dev Uses binary search to efficiently find the appropriate checkpoint
     * @dev If the address has no checkpoints, returns 0
     * @dev If the timestamp is after the latest checkpoint, returns the latest checkpoint index
     * @dev If the timestamp is before the first checkpoint, returns 0
     * @param _owner The address for which to find the checkpoint
     * @param _timestamp The timestamp to query the balance at
     * @return The index of the checkpoint valid at the given timestamp
     */
    function getPriorBalanceIndex(
        address _owner,
        uint256 _timestamp
    ) public view returns (uint256) {
        uint256 nCheckpoints = numCheckpoints[_owner];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[_owner][nCheckpoints - 1].timestamp <= _timestamp) {
            return (nCheckpoints - 1);
        }

        // Next check implicit zero balance
        if (checkpoints[_owner][0].timestamp > _timestamp) {
            return 0;
        }

        uint256 lower = 0;
        uint256 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[_owner][center];
            if (cp.timestamp == _timestamp) {
                return center;
            } else if (cp.timestamp < _timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function getPriorSupplyIndex(
        uint256 _timestamp
    ) public view returns (uint256) {
        uint256 nCheckpoints = supplyNumCheckpoints;
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (supplyCheckpoints[nCheckpoints - 1].timestamp <= _timestamp) {
            return (nCheckpoints - 1);
        }

        // Next check implicit zero balance
        if (supplyCheckpoints[0].timestamp > _timestamp) {
            return 0;
        }

        uint256 lower = 0;
        uint256 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            SupplyCheckpoint memory cp = supplyCheckpoints[center];
            if (cp.timestamp == _timestamp) {
                return center;
            } else if (cp.timestamp < _timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function _writeCheckpoint(address _owner, uint256 _balance) internal {
        uint256 _nCheckPoints = numCheckpoints[_owner];
        uint256 _timestamp = block.timestamp;

        if (
            _nCheckPoints > 0 &&
            ProtocolTimeLibrary.epochStart(
                checkpoints[_owner][_nCheckPoints - 1].timestamp
            ) ==
            ProtocolTimeLibrary.epochStart(_timestamp)
        ) {
            checkpoints[_owner][_nCheckPoints - 1] = Checkpoint(
                _timestamp,
                _balance
            );
        } else {
            checkpoints[_owner][_nCheckPoints] = Checkpoint(
                _timestamp,
                _balance
            );
            numCheckpoints[_owner] = _nCheckPoints + 1;
        }
    }

    function _writeSupplyCheckpoint() internal {
        uint256 _nCheckPoints = supplyNumCheckpoints;
        uint256 _timestamp = block.timestamp;

        if (
            _nCheckPoints > 0 &&
            ProtocolTimeLibrary.epochStart(
                supplyCheckpoints[_nCheckPoints - 1].timestamp
            ) ==
            ProtocolTimeLibrary.epochStart(_timestamp)
        ) {
            supplyCheckpoints[_nCheckPoints - 1] = SupplyCheckpoint(
                _timestamp,
                totalSupply()
            );
        } else {
            supplyCheckpoints[_nCheckPoints] = SupplyCheckpoint(
                _timestamp,
                totalSupply()
            );
            supplyNumCheckpoints = _nCheckPoints + 1;
        }
    }

    function rewardsListLength() external view returns (uint256) {
        return rewards.length;
    }

    function earned(address _token, address _owner) public returns (uint256) {
        if (numCheckpoints[_owner] == 0) {
            return 0;
        }

        uint256 reward = 0;
        uint256 _supply = 1;
        uint256 _currTs = ProtocolTimeLibrary.epochStart(
            lastEarn[_token][_owner]
        ); // take epoch last claimed in as starting point
        uint256 _index = getPriorBalanceIndex(_owner, _currTs);
        Checkpoint memory cp0 = checkpoints[_owner][_index];

        // accounts for case where lastEarn is before first checkpoint
        _currTs = Math.max(
            _currTs,
            ProtocolTimeLibrary.epochStart(cp0.timestamp)
        );

        // get epochs between current epoch and first checkpoint in same epoch as last claim
        uint256 numEpochs = (ProtocolTimeLibrary.epochStart(block.timestamp) -
            _currTs) / DURATION;

        if (numEpochs > 0) {
            for (uint256 i = 0; i < numEpochs; i++) {
                // get index of last checkpoint in this epoch
                _index = getPriorBalanceIndex(_owner, _currTs + DURATION - 1);
                // get checkpoint in this epoch
                cp0 = checkpoints[_owner][_index];
                // get supply of last checkpoint in this epoch
                _supply = Math.max(
                    supplyCheckpoints[
                        getPriorSupplyIndex(_currTs + DURATION - 1)
                    ].supply,
                    1
                );
                reward +=
                    (cp0._balances * tokenRewardsPerEpoch[_token][_currTs]) /
                    _supply;
                if (tokenClaimedPerEpoch[_owner][_token][_currTs] > 0) {
                    reward -= tokenClaimedPerEpoch[_owner][_token][_currTs];
                }
                tokenClaimedPerEpoch[_owner][_token][_currTs] += reward;
                _currTs += DURATION;
            }
        }

        return reward;
    }

    /**
     * @notice Deposits tokens into the rewards contract
     * @dev Can only be called by the authorized address
     * @param _tokenId The ID of the token to deposit
     * @param _amount The amount of tokens to deposit
     * @param _owner The address that will be recorded as the owner of the deposit
     */
    function deposit(
        uint256 _tokenId,
        uint256 _amount,
        address _owner
    ) external {
        address sender = _msgSender();
        if (sender != authorized) revert NotAuthorized();
        if (_amount == 0) revert ZeroAmount();
        if (tokenId != _tokenId) {
            _escrow(_owner, _tokenId, _amount);
            return;
        }
        if(_owner == address(this)) {
            _owner =  IOwnable(loanContract).owner();
        }
        _deposit(_amount, _owner);
    }

    function _deposit(uint256 _amount, address _owner) internal {
        // NOTE: Minting functionality has been deprecated
        // Community reward shares are no longer minted on deposits

        // NOTE: Checkpoint writing has been deprecated along with minting
        // Balance and supply tracking is no longer needed without share minting

        // NOTE: Flight deposit tracking has been deprecated
        // Flight deposit tracking is no longer needed

        // Deposit will still emit an event for accountability
        emit Deposit(_owner, _amount);
    }

    function _escrow(
        address _owner,
        uint256 _tokenId,
        uint256 _amount
    ) internal {
        // Calculate current flight epoch
        uint256 currentFlight = ProtocolTimeLibrary.epochStart(block.timestamp) - 
                               ProtocolTimeLibrary.epochStart(block.timestamp) % (4 * ProtocolTimeLibrary.WEEK);
        
        // Update escrow balance
        uint256 oldBalance = escrowTokenBalance[_owner][_tokenId][currentFlight];
        uint256 newBalance = oldBalance + _amount;
        escrowTokenBalance[_owner][_tokenId][currentFlight] = newBalance;
        
        // Determine credit amount based on threshold
        uint256 creditAmount = 0;
        if (oldBalance >= threshold) {
            // Already over threshold, credit the full amount
            creditAmount = _amount;
        } else if (newBalance >= threshold) {
            // This deposit crosses threshold, credit everything
            creditAmount = newBalance;
        }
        
        // Update deposits if there's an amount to credit
        if (creditAmount > 0) {
            flightDeposits[_owner][currentFlight] += creditAmount;
            totalFlightDeposits[currentFlight] += creditAmount;
        }
    }

    function getReward(address[] memory _tokens) external nonReentrant returns (uint256) {
        return _getReward(msg.sender, _tokens);
    }

    function getRewardForUser(
        address _owner,
        address[] memory _tokens
    ) external nonReentrant returns (uint256) {
        return _getReward(_owner, _tokens);
    }

    function _getReward(address _owner, address[] memory _tokens) internal returns (uint256) {
        uint256 _length = _tokens.length;
        uint256 _totalReward = 0;
        for (uint256 i = 0; i < _length; i++) {
            uint256 _reward = earned(_tokens[i], _owner);
            if (lastNotify[_tokens[i]] == 0) {
                continue;
            }
            // default lastEarn to previous epoch of lastNotify to ensure user collects all due rewards
            lastEarn[_tokens[i]][_owner] =
                ProtocolTimeLibrary.epochStart(lastNotify[_tokens[i]]) -
                ProtocolTimeLibrary.WEEK;
            if (_reward > 0) IERC20(_tokens[i]).safeTransfer(_owner, _reward);

            emit ClaimRewards(_owner, _tokens[i], _reward);
            _totalReward += _reward;
        }
        return _totalReward;
    }

    /**
     * @notice Registers a bonus amount for the previous flight period
     * @dev Calculates the previous flight period timestamp (which appears to be a 4-week period)
     *      and adds the specified amount to the flight bonus for that period.
     *      Only callable by the authorized address.
     * 
     * @param amount The amount of bonus tokens to add to the previous flight period
     * 
     * @custom:throws NotAuthorized if caller is not the authorized address
     * @custom:throws ZeroAmount if amount is zero
     * 
     * @custom:emits NotifyFlightBonus with the previous flight period timestamp and bonus amount
     */
    function notifyFlightBonus(uint256 amount) external {
        address sender = _msgSender();
        if (sender != authorized) revert NotAuthorized();
        if (amount == 0) revert ZeroAmount();

        uint256 previousFlight = ProtocolTimeLibrary.epochStart(block.timestamp) - ProtocolTimeLibrary.epochStart(block.timestamp) % (4 * ProtocolTimeLibrary.WEEK) - 4 * ProtocolTimeLibrary.WEEK;
        flightBonus[previousFlight] += amount;

        emit NotifyFlightBonus(previousFlight, amount);
    }

    /**
     * @notice Allows a user to claim their proportional flight bonus rewards
     * @dev This function calculates and distributes rewards proportionally based on a user's deposit in a flight
     * relative to the total deposits. Implements reentrancy protection.
     * @param owner The address of the user claiming their flight bonus
     * @param flight The identifier of the flight for which the bonus is being claimed
     */
    function claimFlightBonus(address owner, uint256 flight) external nonReentrant returns (uint256) {
        uint256 claimedBonus = flightBonusClaimed[owner][flight];

        uint256 ownerDeposit = flightDeposits[owner][flight];
        uint256 totalDeposit = totalFlightDeposits[flight];
        uint256 bonus = flightBonus[flight];

        if (totalDeposit == 0 || bonus == 0 || ownerDeposit == 0) return 0; 

        uint256 rewardAmount = (ownerDeposit * bonus) / totalDeposit - claimedBonus;
        if (rewardAmount == 0) return 0; // No bonus to claim
        flightBonusClaimed[owner][flight] += rewardAmount;

        _mint(owner, rewardAmount);
        _writeCheckpoint(owner, balanceOf(owner));
        _writeSupplyCheckpoint();

        emit ClaimFlightBonus(owner, flight, rewardAmount);
        return rewardAmount;
    }

    /**
     * @notice Sets the increase percentage for a specific token ID
     * @dev Only callable by the owner of the loan contract
     * @param _increasePercentage The new increase percentage to set
     */
    function setIncreasePercentage(
        uint256 _increasePercentage
    ) external {
        address sender = _msgSender();
        if (sender != IOwnable(loanContract).owner()) revert NotAuthorized();
        ILoan(authorized).setIncreasePercentage(tokenId, _increasePercentage);
    }
}
