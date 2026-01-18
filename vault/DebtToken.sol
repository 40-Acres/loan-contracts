// SPDX-License-Identifier: BUSL-1.1

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
    function getUtilizationPercent() external view returns (uint256);
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
    uint256 public constant MAX_EPOCH_ITERATIONS = 52; // ~1 year of weeks

    struct Checkpoint {
        uint256 _epoch;
        uint256 _balances;
    }

    address public immutable vault;

    struct SupplyCheckpoint {
        uint256 _epoch;
        uint256 _supply;
    }
    mapping(address => mapping(uint256 => Checkpoint)) public checkpoints;
    mapping(address => uint256) public numCheckpoints;

    uint256 public constant PRECISION = 1e18;

    //total assets per epoch
    mapping(uint256 => uint256) public totalAssetsPerEpoch;
    //total supply per epoch
    mapping(uint256 => uint256) public totalSupplyPerEpoch;

    //supply checkpoints
    mapping(uint256 => SupplyCheckpoint) public supplyCheckpoints;
    uint256 public supplyNumCheckpoints;

    // token claimed per epoch
    mapping(address => mapping(uint256 => uint256)) public tokenClaimedPerEpoch;

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

        uint256 epoch = ProtocolTimeLibrary.epochStart(_timestamp);

        // First check most recent balance
        if (checkpoints[_owner][nCheckpoints - 1]._epoch <= epoch) {
            return (nCheckpoints - 1);
        }

        // Next check implicit zero balance
        if (checkpoints[_owner][0]._epoch > epoch) {
            return 0;
        }

        uint256 lower = 0;
        uint256 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[_owner][center];
            if (cp._epoch == epoch) {
                return center;
            } else if (cp._epoch < epoch) {
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
        uint256 _timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);

        if (
            _nCheckPoints > 0 &&
            checkpoints[_owner][_nCheckPoints - 1]._epoch ==
            _timestamp
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
        uint256 _timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);

        if (
            _nCheckPoints > 0 &&
            supplyCheckpoints[_nCheckPoints - 1]._epoch ==
            _timestamp
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


    function totalAssets() public view returns (uint256) {
        return totalAssetsPerEpoch[ProtocolTimeLibrary.epochStart(block.timestamp)];
    }

    function totalAssets(uint256 epoch) public view returns (uint256) {
        epoch = ProtocolTimeLibrary.epochStart(epoch);
        // disburse assets evenly over the epoch via block.timestamp
        uint256 currentTimestamp = block.timestamp;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(currentTimestamp);
        // Only prorate for the current epoch; for past epochs, return full assets
        if (currentEpoch == epoch) {
            uint256 assets = totalAssetsPerEpoch[epoch];
            uint256 duration = ProtocolTimeLibrary.epochNext(epoch) - epoch;
            uint256 elapsed = currentTimestamp - epoch;
            // Multiply before divide to avoid precision loss
            uint256 prorated = (assets * elapsed) / duration;
            return prorated;
        }
        // For past epochs, return the full assets
        return totalAssetsPerEpoch[epoch];
    }


    function getReward(address _owner) external returns (uint256) {
        require(msg.sender == vault, "Only vault can get rewards");
        return _getReward(_owner);
    }

    function _getReward(address _owner) internal returns (uint256) {
        // Calculate earned rewards (this updates tokenClaimedPerEpoch for each epoch)
        uint256 _reward = earned(_owner);

        return _reward;
    }

    function lenderPremiumUnlockedThisEpoch() public returns (uint256) {
        // Call earned to update tokenClaimedPerEpoch for the current epoch
        earned(vault);

        uint256 _epoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        return tokenClaimedPerEpoch[vault][_epoch];
    }


    function debtRepaidThisEpoch() public returns (uint256) {
        uint256 _epoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        return totalAssets(_epoch) - lenderPremiumUnlockedThisEpoch();
    }

    /// @notice Calculate earned rewards for an owner
    /// @param _owner The address to calculate rewards for
    /// @return The amount of rewards earned
    function earned(address _owner) public returns (uint256) {
        if (numCheckpoints[_owner] == 0) {
            return 0;
        }

        uint256 reward = 0;
        uint256 _supply = 1;
        uint256 _currTs = ProtocolTimeLibrary.epochStart(block.timestamp);
        uint256 _index = getPriorBalanceIndex(_owner, _currTs);
        Checkpoint memory cp0 = checkpoints[_owner][_index];

        // accounts for case where lastEarn is before first checkpoint
        _currTs = Math.max(_currTs, ProtocolTimeLibrary.epochStart(cp0._epoch));

        // get epochs between current epoch and first checkpoint in same epoch as last claim
        uint256 currentEpochStart = ProtocolTimeLibrary.epochStart(block.timestamp);
        if (_currTs >= DURATION) {
            _currTs = _currTs - DURATION;
        }
        uint256 numEpochs = 0;
        if (currentEpochStart >= _currTs) {
            numEpochs = ((currentEpochStart - _currTs) / DURATION) + 1;
        }

        // Limit iterations to prevent DOS attacks from stale checkpoints
        if (numEpochs > MAX_EPOCH_ITERATIONS) {
            numEpochs = MAX_EPOCH_ITERATIONS;
        }

        if (numEpochs > 0) {
            for (uint256 i = 0; i < numEpochs; i++) {
                uint256 epoch = _currTs;
                _supply = Math.max(totalSupply(epoch), 1);
                uint256 assetsUnlocked = totalAssets(epoch);

                // Skip epochs with no assets
                if (assetsUnlocked == 0) {
                    _currTs += DURATION;
                    continue;
                }

                // Get the balance at the START of this epoch (before any mints in this epoch)
                uint256 queryTimestamp = _currTs > 0 ? _currTs - 1 : _currTs;
                _index = getPriorBalanceIndex(_owner, queryTimestamp);

                uint256 nCheckpoints = numCheckpoints[_owner];
                if (_index >= nCheckpoints) {
                    _currTs += DURATION;
                    continue;
                }

                cp0 = checkpoints[_owner][_index];

                // Ensure the checkpoint is from before the start of this epoch
                uint256 cpEpoch = ProtocolTimeLibrary.epochStart(cp0._epoch);
                while (cpEpoch >= _currTs && _index > 0) {
                    _index = _index - 1;
                    cp0 = checkpoints[_owner][_index];
                    cpEpoch = ProtocolTimeLibrary.epochStart(cp0._epoch);
                }

                uint256 epochReward = (cp0._balances * assetsUnlocked) / _supply;
                uint256 alreadyClaimed = tokenClaimedPerEpoch[_owner][epoch];
                uint256 newReward = epochReward > alreadyClaimed ? epochReward - alreadyClaimed : 0;

                tokenClaimedPerEpoch[_owner][epoch] = epochReward;
                reward += newReward;
                _currTs += DURATION;
            }
        }

        return reward;
    }

    /**
     * @notice Mints debt tokens to a specified address
     * @dev Only callable by the authorized address
     * @dev Updates balance checkpoints, supply checkpoints, and totalSupplyPerEpoch
     * @param _to The address to mint tokens to
     * @param _amount The amount of tokens to mint
     */
    function _mint(address _to, uint256 _amount) internal {
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        // Get current balance and calculate new balance
        uint256 currentBalance = _getCurrentBalance(_to);
        
        // mint assets 
        totalAssetsPerEpoch[currentEpoch] += _amount;

        uint256 newBalance = currentBalance + _amount;

        // Update balance checkpoint
        _writeCheckpoint(_to, newBalance);

        _rebalance();

        emit Mint(_to, _amount);
    }


    function mint(address _to, uint256 _amount) virtual external {
        if (msg.sender != vault) revert NotAuthorized();
        if (_amount == 0) revert ZeroAmount();
        _mint(_to, _amount);
    }

    function rebalance() external {
        if (msg.sender != vault) revert NotAuthorized();
        _rebalance();
    }

    function _rebalance() internal {
        uint256 supply = totalSupply();
        uint256 utilizationBps = IDynamicFeesVault(vault).getUtilizationPercent();
        uint256 ratio = getVaultRatioBps(utilizationBps);
        if (ratio > 0 && ratio < 10000) {
            uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

            // Now calculate the new vault balance to maintain the ratio
            uint256 newVaultBalance = (totalAssetsPerEpoch[currentEpoch] * ratio) / (10000 - ratio);
            totalSupplyPerEpoch[currentEpoch] = totalAssetsPerEpoch[currentEpoch] + newVaultBalance;
            _writeCheckpoint(vault, newVaultBalance);
            _writeSupplyCheckpoint();
        }
    }
    
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view virtual returns (uint256) {
        return _convertToAssets(shares, rounding, ProtocolTimeLibrary.epochStart(block.timestamp));
    }
    
    function _convertToAssets(uint256 shares, Math.Rounding rounding, uint256 epoch) internal view virtual returns (uint256) {
        uint256 epochSupply = totalSupply(epoch);
        // If totalSupply is 0, there's no supply in this epoch, so rewards should be 0
        if (epochSupply == 0) {
            return 0;
        }

        // For reward calculation, use totalAssetsUnlocked which returns:
        // - Full assets for past epochs
        // - Prorated assets for current epoch (based on elapsed time)
        uint256 assetsUnlocked = totalAssets(epoch);
        // Use standard mulDiv without offsets - we already handle epochSupply == 0 case above
        return shares.mulDiv(assetsUnlocked, epochSupply, rounding);
    }

    function _decimalsOffset() internal view virtual returns (uint8) {
        return 0;
    }

    function getCurrentVaultRatioBps() public view virtual returns (uint256) {
        return getVaultRatioBps(IDynamicFeesVault(vault).getUtilizationPercent());
    }

    
    /**
     * @notice Gets the vault ratio in basis points
     * @param utilizationBps The utilization rate in basis points (e.g., 8000 = 80%)
     * @return rate The vault ratio in basis points (e.g., 8000 = 80%), which means the vault should hold 80% of the total supply
     */
    function getVaultRatioBps(uint256 utilizationBps) public view virtual returns (uint256 rate) {        
        require(utilizationBps <= 10000, "Utilization exceeds 100%");
        
        if (utilizationBps <= 1000) {
            // 0-10%: Quadratic curve from 500 to 2000 bps (5% to 20%)
            uint256 t = (utilizationBps * PRECISION) / 1000;
            rate = 500 + (1500 * t * t) / (PRECISION * PRECISION);
        } 
        else if (utilizationBps <= 7000) {
            // 10-70%: Flat at 2000 bps (20%)
            rate = 2000;
        } 
        else if (utilizationBps <= 9000) {
            // 70-90%: Gradual quadratic curve from 2000 to 4000 bps (20% to 40%)
            uint256 segment = utilizationBps - 7000;
            uint256 t = (segment * PRECISION) / 2000;
            rate = 2000 + (2000 * t * t) / (PRECISION * PRECISION);
        } 
        else {
            // 90-100%: Steep quadratic curve from 4000 to 9500 bps (40% to 95%)
            uint256 segment = utilizationBps - 9000;
            uint256 t = (segment * PRECISION) / 1000;
            rate = 4000 + (5500 * t * t) / (PRECISION * PRECISION);
        }
        
        return rate;
    }

    function getUtilizationPercent() public view virtual returns (uint256) {
        revert("Not implemented");
    }
}