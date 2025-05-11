// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IReward} from "../interfaces/IReward.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolTimeLibrary} from "../libraries/ProtocolTimeLibrary.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Base reward contract for distribution of rewards
contract CommunityRewards is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidReward();
    error NotAuthorized();
    error ZeroAmount();

    event Deposit(address indexed from, uint256 amount);
    event Withdraw(address indexed from, uint256 amount);
    event NotifyReward(address indexed from, address indexed reward, uint256 indexed epoch, uint256 amount);
    event ClaimRewards(address indexed from, address indexed reward, uint256 amount);

    uint256 public constant DURATION = 7 days;

    /// @dev Address which has permission to externally call _deposit() & _withdraw()
    address public authorized;

    mapping(address => mapping(uint256 => uint256)) public tokenRewardsPerEpoch;
    mapping(address => mapping(address => mapping(uint256 => uint256))) public tokenClaimedPerEpoch;
    mapping(address => mapping(address => uint256)) public lastEarn;
    mapping(address => uint256) public lastNotify;

    address[] public rewards;
    mapping(address => bool) public isReward;
    uint256 public tokenId; // tokenId of the Community Token

    uint256 threshold; // threshold for rewards
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public escrowTokenBalance; // mapping of account[tokenId][epoch] to balance
    mapping(uint256 => bool) public flightSchoolReceived; //mapping of epoch to bool to check if flight school has been received for that epoch

    /// @notice A checkpoint for marking balance
    struct Checkpoint {
        uint256 timestamp;
        uint256 _balances;
    }

    /// @notice A checkpoint for marking supply
    struct SupplyCheckpoint {
        uint256 timestamp;
        uint256 supply;
    }

    /// @notice A record of balance checkpoints for each account, by index
    mapping(address => mapping(uint256 => Checkpoint)) public checkpoints;
    /// @notice The number of checkpoints for each account
    mapping(address => uint256) public numCheckpoints;
    /// @notice A record of balance checkpoints for each token, by index
    mapping(uint256 => SupplyCheckpoint) public supplyCheckpoints;
    /// @notice The number of checkpoints
    uint256 public supplyNumCheckpoints;

    constructor(address _loanContract, address[] memory _rewards, uint256 _threshold) ERC20("40AcresCommunityRewards", "40A-Community-Rewards") {
        uint256 _length = _rewards.length;
        for (uint256 i; i < _length; i++) {
            if (_rewards[i] != address(0)) {
                isReward[_rewards[i]] = true;
                rewards.push(_rewards[i]);
            }
        }
        rewards.push(address(this)); // add this contract to the list of rewards
        authorized = _loanContract;
    }

    function transfer(address _recipient, uint256 _amount) public override nonReentrant returns (bool) {
        address sender = _msgSender();

        _transfer(sender, _recipient, _amount);

        _writeCheckpoint(_recipient, balanceOf(_recipient));
        _writeCheckpoint(sender, balanceOf(sender));

        return true;
    }

    function notifyRewardAmount(address _token, uint256 _amount) external  nonReentrant {
        address sender = _msgSender();
        require(sender == authorized);
        if (_amount == 0) revert ZeroAmount();
        if (!isReward[_token]) revert InvalidReward();
        IERC20(_token).safeTransferFrom(sender, address(this), _amount);

        // we send the reward to the previous epoch since rewards are distributed at the end of the epoch
        uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp) - ProtocolTimeLibrary.WEEK;
        tokenRewardsPerEpoch[_token][epochStart] += _amount;

        lastNotify[_token] = block.timestamp;
        
        emit NotifyReward(sender, _token, epochStart, _amount);
    }

    function getPriorBalanceIndex(address _owner, uint256 _timestamp) public view returns (uint256) {
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

    function getPriorSupplyIndex(uint256 _timestamp) public view returns (uint256) {
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
            ProtocolTimeLibrary.epochStart(checkpoints[_owner][_nCheckPoints - 1].timestamp) ==
            ProtocolTimeLibrary.epochStart(_timestamp)
        ) {
            checkpoints[_owner][_nCheckPoints - 1] = Checkpoint(_timestamp, _balance);
        } else {
            checkpoints[_owner][_nCheckPoints] = Checkpoint(_timestamp, _balance);
            numCheckpoints[_owner] = _nCheckPoints + 1;
        }
    }

    function _writeSupplyCheckpoint() internal {
        uint256 _nCheckPoints = supplyNumCheckpoints;
        uint256 _timestamp = block.timestamp;

        if (
            _nCheckPoints > 0 &&
            ProtocolTimeLibrary.epochStart(supplyCheckpoints[_nCheckPoints - 1].timestamp) ==
            ProtocolTimeLibrary.epochStart(_timestamp)
        ) {
            supplyCheckpoints[_nCheckPoints - 1] = SupplyCheckpoint(_timestamp, totalSupply());
        } else {
            supplyCheckpoints[_nCheckPoints] = SupplyCheckpoint(_timestamp, totalSupply());
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
        uint256 _currTs = ProtocolTimeLibrary.epochStart(lastEarn[_token][_owner]); // take epoch last claimed in as starting point
        uint256 _index = getPriorBalanceIndex(_owner, _currTs);
        Checkpoint memory cp0 = checkpoints[_owner][_index];

        // accounts for case where lastEarn is before first checkpoint
        _currTs = Math.max(_currTs, ProtocolTimeLibrary.epochStart(cp0.timestamp));

        // get epochs between current epoch and first checkpoint in same epoch as last claim
        uint256 numEpochs = (ProtocolTimeLibrary.epochStart(block.timestamp) - _currTs) / DURATION;

        if (numEpochs > 0) {
            for (uint256 i = 0; i < numEpochs; i++) {
                // get index of last checkpoint in this epoch
                _index = getPriorBalanceIndex(_owner, _currTs + DURATION - 1);
                // get checkpoint in this epoch
                cp0 = checkpoints[_owner][_index];
                // get supply of last checkpoint in this epoch
                _supply = Math.max(supplyCheckpoints[getPriorSupplyIndex(_currTs + DURATION - 1)].supply, 1);
                reward += (cp0._balances * tokenRewardsPerEpoch[_token][_currTs]) / _supply;
                if(tokenClaimedPerEpoch[_owner][_token][_currTs] > 0) {
                    reward -= tokenClaimedPerEpoch[_owner][_token][_currTs];
                }
                tokenClaimedPerEpoch[_owner][_token][_currTs] += reward;
                _currTs += DURATION;
            }
        }

        return reward;
    }

    function deposit(uint256 _tokenId, uint256 _amount, address _owner) external {
        address sender = _msgSender();
        if(sender != authorized) revert NotAuthorized();
        if(_amount == 0) revert ZeroAmount();
        if(tokenId != _tokenId)  {
            // increase the escrowTokenBalance for the user
            escrowTokenBalance[_owner][_tokenId][ProtocolTimeLibrary.epochStart(block.timestamp)] += _amount;
        }
    }
    
    function _deposit(uint256 _amount, address _owner) internal {
        address sender = _msgSender();
        if (sender != authorized) revert NotAuthorized();

        _mint(_owner, _amount);

        _writeCheckpoint(_owner, balanceOf(_owner));
        _writeSupplyCheckpoint();

        emit Deposit(sender, _amount);
    }

    function getReward(address[] memory _tokens) external nonReentrant {
        _getReward(msg.sender, _tokens);
    }

    function _getReward(
        address _owner,
        address[] memory _tokens
    ) internal {
        uint256 _length = _tokens.length;
        for (uint256 i = 0; i < _length; i++) {
            uint256 _reward = earned(_tokens[i], _owner); 
            if(lastNotify[_tokens[i]] == 0) {
                continue;
            }
            // default lastEarn to previous epoch of lastNotify to ensure user collects all due rewards 
            lastEarn[_tokens[i]][_owner] = ProtocolTimeLibrary.epochStart(lastNotify[_tokens[i]]) - ProtocolTimeLibrary.WEEK;
            if (_reward > 0) IERC20(_tokens[i]).safeTransfer(_owner, _reward);

            emit ClaimRewards(_owner, _tokens[i], _reward);
        }
    }
}