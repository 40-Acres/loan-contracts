// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ProtocolTimeLibrary } from "../src/libraries/ProtocolTimeLibrary.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


interface IDynamicFeesVault {
    function decreaseTotalLoanedAssets(uint256 amount) external;
}

/**
 * @title DebtToken
 * @notice Abstract contract for debt tokens
 * @dev This contract is used to track the lender premium and amount paid down to a borower's balance over time
 * @dev This is entirely used for accounting purposes, the payments are send to the vault and all assets are held there
 */
contract DebtToken {
    using Math for uint256;
    using SafeERC20 for IERC20;

    
    error InvalidReward();
    error NotAuthorized();
    error ZeroAmount();
    event Deposit(address indexed from, uint256 amount);
    event Withdraw(address indexed from, uint256 amount);
    event Mint(address indexed to, uint256 amount);
    event NotifyReward(
        address indexed from,
        address indexed reward,
        uint256 indexed epoch,
        uint256 amount
    );
    event ClaimRewards(
        address indexed from,
        address indexed reward,
        uint256 amount
    );

    uint256 public constant DURATION = 7 days;

    address public authorized;

    mapping(address => mapping(uint256 => uint256)) public tokenRewardsPerEpoch;


    mapping(address => mapping(address => mapping(uint256 => uint256)))
        public tokenClaimedPerEpoch;

    mapping(address => mapping(address => uint256)) public lastEarn;

    mapping(address => uint256) public lastNotify;


    address[] public rewards;

    mapping(address => bool) public isReward;

    uint256 public tokenId;

    struct Checkpoint {
        uint256 timestamp;
        uint256 _balances;
    }

    address public loanContract;
    address public immutable vault;

    struct SupplyCheckpoint {
        uint256 timestamp;
        uint256 supply;
    }
    mapping(address => mapping(uint256 => Checkpoint)) public checkpoints;
    mapping(address => uint256) public numCheckpoints;
    mapping(uint256 => SupplyCheckpoint) public supplyCheckpoints;
    uint256 public supplyNumCheckpoints;

    

    mapping(uint256 => uint256) public totalSupplyPerEpoch;

    mapping(uint256 => uint256) public totalAssetsPerEpoch;

    uint256 public constant PRECISION = 1e18;


    constructor(address _vault, address _debtToken) {
        vault = _vault;
        // debtToken = _debtToken;
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

    /**
     * @notice Gets the current balance for an address from checkpoints
     * @param _owner The address to get the balance for
     * @return The current balance from the latest checkpoint, or 0 if no checkpoints exist
     */
    function _getCurrentBalance(address _owner) internal view returns (uint256) {
        uint256 nCheckpoints = numCheckpoints[_owner];
        if (nCheckpoints == 0) {
            return 0;
        }
        return checkpoints[_owner][nCheckpoints - 1]._balances;
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

    function totalSupply() public view returns (uint256) {
        return totalSupplyPerEpoch[ProtocolTimeLibrary.epochStart(block.timestamp)];
    }

    function totalSupply(uint256 epoch) public view returns (uint256) {
        return totalSupplyPerEpoch[epoch];
    }

    function rewardsListLength() external view returns (uint256) {
        return rewards.length;
    }

    function totalAssets() public view returns (uint256) {
        return totalAssetsPerEpoch[ProtocolTimeLibrary.epochStart(block.timestamp)];
    }

    function totalAssetsUnlocked(uint256 epoch) public view returns (uint256) {
        // disburse assets evenly over the epoch via block.timestamp
        uint256 currentTimestamp = block.timestamp;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(currentTimestamp);
        if(currentEpoch == epoch) {
            uint256 assets = totalAssetsPerEpoch[epoch];
            uint256 duration = ProtocolTimeLibrary.epochNext(epoch) - epoch;
            // Calculate assets per second (duration is in seconds)
            uint256 assetsPerSecond = assets / duration;
            // Return the proportion of assets that have been distributed up to now
            return assetsPerSecond * (currentTimestamp - epoch);
        }
        return totalAssetsPerEpoch[epoch];
    }


    function lenderPremiumUnlockedThisEpoch() public returns (uint256) {
        earned(address(this), vault);

        uint256 _epoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        return tokenClaimedPerEpoch[vault][address(this)][_epoch];
    }

    function debtRepaidThisEpoch() public returns (uint256) {
        uint256 _epoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        return totalAssetsUnlocked(_epoch) - lenderPremiumUnlockedThisEpoch();
    }

    function earned(address _token, address _owner) public returns (uint256) {
        if (numCheckpoints[_owner] == 0) {
            return 0;
        }

        uint256 reward = 0;
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
                
                // Calculate the reward for this epoch: convert balance (shares) to assets
                uint256 epochReward = _convertToAssets(cp0._balances, Math.Rounding.Floor, _currTs);
                
                // Subtract what was already claimed for this epoch
                uint256 alreadyClaimed = tokenClaimedPerEpoch[_owner][_token][_currTs];
                uint256 newReward = epochReward > alreadyClaimed ? epochReward - alreadyClaimed : 0;
                
                // Update the claimed amount for this epoch
                tokenClaimedPerEpoch[_owner][_token][_currTs] = epochReward;
                
                // Add to total reward
                reward += newReward;
                
                _currTs += DURATION;
            }
        }

        return reward;
    }


    function getReward(address[] memory _tokens) external returns (uint256) {
        return _getReward(msg.sender, _tokens);
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
     * @notice Mints debt tokens to a specified address
     * @dev Only callable by the authorized address
     * @dev Updates balance checkpoints, supply checkpoints, and totalSupplyPerEpoch
     * @param _to The address to mint tokens to
     * @param _amount The amount of tokens to mint
     */
    function _mint(address _to, uint256 _amount) internal {
        // Get current balance and calculate new balance
        uint256 currentBalance = _getCurrentBalance(_to);
        
        // mint assets 
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        totalAssetsPerEpoch[currentEpoch] += _amount;

        uint256 newBalance = currentBalance + _amount;

        // Update balance checkpoint
        _writeCheckpoint(_to, newBalance);

        totalSupplyPerEpoch[currentEpoch] += _amount;

        _rebalance();

        // Update supply checkpoint
        _writeSupplyCheckpoint();

        emit Mint(_to, _amount);
    }


    function mint(address _to, uint256 _amount) virtual external {
        if (msg.sender != vault) revert NotAuthorized();
        if (_amount == 0) revert ZeroAmount();
        _mint(_to, _amount);
    }

    function rebalance() external {
        _rebalance();
    }

    function _rebalance() internal {
        uint256 supply = totalSupply();
        if (supply == 0) return; // Nothing to rebalance if there's no supply yet
        uint256 utilizationPercent = totalAssets() * 10000 / supply;
        uint256 ratio = getVaultRatioBps(utilizationPercent);
        if (ratio > 0 && ratio < 10000) {
            uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
            uint256 vaultBalance = _getCurrentBalance(vault);

            // Remove the vault balance from the total supply only if it exists in this epoch
            // Check if vault has a checkpoint in the current epoch
            uint256 vaultCheckpoints = numCheckpoints[vault];
            if (vaultCheckpoints > 0) {
                uint256 lastCheckpointIndex = vaultCheckpoints - 1;
                uint256 lastCheckpointEpoch = ProtocolTimeLibrary.epochStart(
                    checkpoints[vault][lastCheckpointIndex].timestamp
                );
                
                // Only subtract vault balance if it's from the current epoch
                if (lastCheckpointEpoch == currentEpoch && vaultBalance <= totalSupplyPerEpoch[currentEpoch]) {
                    totalSupplyPerEpoch[currentEpoch] -= vaultBalance;
                }
            }

            // Now calculate the new vault balance to maintain the ratio
            // newVaultBalance = userSupply * vaultRatioBps / (10000 - vaultRatioBps)
            uint256 newVaultBalance = (totalSupplyPerEpoch[currentEpoch] * ratio) / (10000 - ratio);
            
            totalSupplyPerEpoch[currentEpoch] += newVaultBalance;
            _writeCheckpoint(vault, newVaultBalance);
        }
    }
    
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view virtual returns (uint256) {
        return _convertToAssets(shares, rounding, ProtocolTimeLibrary.epochStart(block.timestamp));
    }
    
    function _convertToAssets(uint256 shares, Math.Rounding rounding, uint256 epoch) internal view virtual returns (uint256) {
        return shares.mulDiv(totalAssetsUnlocked(epoch) + 1, totalSupply(epoch) + 10 ** _decimalsOffset(), rounding);
    }

    function _decimalsOffset() internal view virtual returns (uint8) {
        return 0;
    }


    
    /**
     * @notice Gets the vault ratio in basis points
     * @param utilizationPercent The utilization rate in basis points (e.g., 8000 = 80%)
     * @return rate The vault ratio in basis points (e.g., 8000 = 80%), which means the vault should hold 80% of the total supply
     */
    function getVaultRatioBps(uint256 utilizationPercent) public view virtual returns (uint256 rate) {        
        require(utilizationPercent <= 100, "Utilization exceeds 100%");
        
        if (utilizationPercent <= 10) {
            // 0-10%: Quadratic curve from 5 to 20
            uint256 t = (utilizationPercent * PRECISION) / 10;
            rate = 5 + (15 * t * t) / (PRECISION * PRECISION);
        } 
        else if (utilizationPercent <= 70) {
            // 10-70%: Flat at 20
            rate = 20;
        } 
        else if (utilizationPercent <= 90) {
            // 70-90%: Gradual quadratic curve from 20 to 40
            uint256 segment = utilizationPercent - 70;
            uint256 t = (segment * PRECISION) / 20;
            rate = 20 + (20 * t * t) / (PRECISION * PRECISION);
        } 
        else {
            // 90-100%: Steep quadratic curve from 40 to 95
            uint256 segment = utilizationPercent - 90;
            uint256 t = (segment * PRECISION) / 10;
            rate = 40 + (55 * t * t) / (PRECISION * PRECISION);
        }
        
        return rate;
    }

    function getUtilizationPercent() public view virtual returns (uint256) {
        revert("Not implemented");
    }
}