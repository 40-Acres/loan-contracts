// SPDX-License-Identifier: MIT
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
    error NotGauge();
    error NotEscrowToken();
    error NotSingleToken();
    error NotVotingEscrow();
    error NotWhitelisted();
    error ZeroAmount();

    event Deposit(address indexed from, uint256 amount);
    event Withdraw(address indexed from, uint256 amount);
    event NotifyReward(address indexed from, address indexed reward, uint256 indexed epoch, uint256 amount);
    event ClaimRewards(address indexed from, address indexed reward, uint256 amount);


    uint256 public constant DURATION = 7 days;

    /// @dev Address which has permission to externally call _deposit() & _withdraw()
    address public authorized;

    mapping(address => mapping(uint256 => uint256)) public tokenRewardsPerEpoch;
    mapping(address => mapping(address => uint256)) public lastEarn;
    mapping(address => uint256) public lastEarnedEpoch;

    address[] public rewards;
    mapping(address => bool) public isReward;

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



    constructor(address loanContract, address[] memory _rewards) ERC20("40AcresCommunityRewards", "40A-Community-Rewards") {
        uint256 _length = _rewards.length;
        for (uint256 i; i < _length; i++) {
            if (_rewards[i] != address(0)) {
                isReward[_rewards[i]] = true;
                rewards.push(_rewards[i]);
            }
        }
        authorized = loanContract;
    }

    function transfer(address recipient, uint256 amount) public override nonReentrant  returns (bool) {
        address sender = _msgSender();

        _transfer(sender, recipient, amount);

        _writeCheckpoint(recipient, balanceOf(recipient));
        _writeCheckpoint(sender, balanceOf(sender));

        return true;
    }


    function notifyRewardAmount(address token, uint256 amount) external  nonReentrant {
        address sender = _msgSender();
        if (amount == 0) revert ZeroAmount();
        if (!isReward[token]) revert InvalidReward();
        IERC20(token).safeTransferFrom(sender, address(this), amount);

        // we send the reward to the previous epoch since rewards are distributed at the end of the epoch
        uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp) - ProtocolTimeLibrary.WEEK;
        tokenRewardsPerEpoch[token][epochStart] += amount;

        if (lastEarnedEpoch[token] < epochStart) {
            lastEarnedEpoch[token] = epochStart;
        }
        emit NotifyReward(sender, token, epochStart, amount);
    }

    function getPriorBalanceIndex(address owner, uint256 timestamp) public view returns (uint256) {
        uint256 nCheckpoints = numCheckpoints[owner];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[owner][nCheckpoints - 1].timestamp <= timestamp) {
            return (nCheckpoints - 1);
        }

        // Next check implicit zero balance
        if (checkpoints[owner][0].timestamp > timestamp) {
            return 0;
        }

        uint256 lower = 0;
        uint256 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[owner][center];
            if (cp.timestamp == timestamp) {
                return center;
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function getPriorSupplyIndex(uint256 timestamp) public view returns (uint256) {
        uint256 nCheckpoints = supplyNumCheckpoints;
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (supplyCheckpoints[nCheckpoints - 1].timestamp <= timestamp) {
            return (nCheckpoints - 1);
        }

        // Next check implicit zero balance
        if (supplyCheckpoints[0].timestamp > timestamp) {
            return 0;
        }

        uint256 lower = 0;
        uint256 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            SupplyCheckpoint memory cp = supplyCheckpoints[center];
            if (cp.timestamp == timestamp) {
                return center;
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function _writeCheckpoint(address owner, uint256 balance) internal {
        uint256 _nCheckPoints = numCheckpoints[owner];
        uint256 _timestamp = block.timestamp;

        if (
            _nCheckPoints > 0 &&
            ProtocolTimeLibrary.epochStart(checkpoints[owner][_nCheckPoints - 1].timestamp) ==
            ProtocolTimeLibrary.epochStart(_timestamp)
        ) {
            checkpoints[owner][_nCheckPoints - 1] = Checkpoint(_timestamp, balance);
        } else {
            checkpoints[owner][_nCheckPoints] = Checkpoint(_timestamp, balance);
            numCheckpoints[owner] = _nCheckPoints + 1;
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

    function earned(address token, address owner) public view returns (uint256) {
        if (numCheckpoints[owner] == 0) {
            return 0;
        }

        uint256 reward = 0;
        uint256 _supply = 1;
        uint256 _currTs = ProtocolTimeLibrary.epochStart(lastEarn[token][owner]); // take epoch last claimed in as starting point
        uint256 _index = getPriorBalanceIndex(owner, _currTs);
        Checkpoint memory cp0 = checkpoints[owner][_index];

        // accounts for case where lastEarn is before first checkpoint
        _currTs = Math.max(_currTs, ProtocolTimeLibrary.epochStart(cp0.timestamp));

        // get epochs between current epoch and first checkpoint in same epoch as last claim
        uint256 numEpochs = (ProtocolTimeLibrary.epochStart(block.timestamp) - _currTs) / DURATION;

        if (numEpochs > 0) {
            for (uint256 i = 0; i < numEpochs; i++) {
                // get index of last checkpoint in this epoch
                _index = getPriorBalanceIndex(owner, _currTs + DURATION - 1);
                // get checkpoint in this epoch
                cp0 = checkpoints[owner][_index];
                // get supply of last checkpoint in this epoch
                _supply = Math.max(supplyCheckpoints[getPriorSupplyIndex(_currTs + DURATION - 1)].supply, 1);
                reward += (cp0._balances * tokenRewardsPerEpoch[token][_currTs]) / _supply;
                _currTs += DURATION;
            }
        }

        return reward;
    }

    function _deposit(uint256 amount, address owner) external {
        address sender = _msgSender();
        if (sender != authorized) revert NotAuthorized();

        _mint(owner, amount);

        _writeCheckpoint(owner, balanceOf(owner));
        _writeSupplyCheckpoint();

        emit Deposit(sender, amount);
    }

    function _withdraw(uint256 amount, address owner) external {
       revert();
    }

    function getReward(address[] memory tokens) external nonReentrant {
        _getReward(msg.sender, tokens);
    }

    /// @dev used with all getReward implementations
    function _getReward(
        address owner,
        address[] memory tokens
    ) internal {
        uint256 _length = tokens.length;
        for (uint256 i = 0; i < _length; i++) {
            uint256 _reward = earned(tokens[i], owner);
            lastEarn[tokens[i]][owner] = block.timestamp;
            if (_reward > 0) IERC20(tokens[i]).safeTransfer(owner, _reward);

            emit ClaimRewards(owner, tokens[i], _reward);
        }
    }
}