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
import {console} from "forge-std/console.sol";

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

    address public authorized;


    mapping(address => mapping(address => uint256)) public lastEarn;
    
    struct Checkpoint {
        uint256 timestamp;
        uint256 _balances;
        uint256 alreadyClaimed;
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

    function _getBalanceAtTimestamp(address _owner, uint256 _timestamp) internal view returns (uint256) {
        uint256 nCheckpoints = numCheckpoints[_owner];
        if (nCheckpoints == 0) {
            return 0;
        }
        uint256 index = getPriorBalanceIndex(_owner, _timestamp);
        return checkpoints[_owner][index]._balances;
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
            uint256 alreadyClaimed = checkpoints[_owner][_nCheckPoints - 1].alreadyClaimed;
            checkpoints[_owner][_nCheckPoints - 1] = Checkpoint(
                _timestamp,
                _balance,
                alreadyClaimed
            );
        } else {
            uint256 alreadyClaimed = checkpoints[_owner][_nCheckPoints - 1].alreadyClaimed;   
            checkpoints[_owner][_nCheckPoints] = Checkpoint(
                _timestamp,
                _balance,
                alreadyClaimed
            );
            numCheckpoints[_owner] = _nCheckPoints + 1;
        }
    }

    function _writeSupplyCheckpoint() internal {
        uint256 _nCheckPoints = supplyNumCheckpoints;
        uint256 _timestamp = block.timestamp;

        // Overwrite checkpoint if we're in the same epoch (since totalSupply is recalculated from scratch on each rebalance)
        // Create new checkpoint only when entering a new epoch (clean slate for new epoch)
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
        console.log("+++++totalSupply", totalSupplyPerEpoch[ProtocolTimeLibrary.epochStart(block.timestamp)]);
        return totalSupplyPerEpoch[ProtocolTimeLibrary.epochStart(block.timestamp)];
    }

    function totalSupply(uint256 epoch) public view returns (uint256) {
        return totalSupplyPerEpoch[epoch];
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
        return checkpoints[vault][_epoch].alreadyClaimed;
    }

    function debtRepaidThisEpoch() public returns (uint256) {
        uint256 _epoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        return totalAssetsUnlocked(_epoch) - lenderPremiumUnlockedThisEpoch();
    }

    function earned(address _token, address _owner) internal returns (uint256) {
        if (numCheckpoints[_owner] == 0) {
            return 0;
        }

        uint256 reward = 0;
        uint256 _currTs = ProtocolTimeLibrary.epochStart(
            lastEarn[_token][_owner]
        ); // take epoch last claimed in as starting point
        uint256 _index = getPriorBalanceIndex(_owner, _currTs);
        Checkpoint memory cp0 = checkpoints[_owner][_index];

        console.log("lastEarn[_token][_owner]", lastEarn[_token][_owner]);
        console.log("numCheckpoints[_owner]", numCheckpoints[_owner]);
        console.log("checkpoints[_owner][0].timestamp", checkpoints[_owner][0].timestamp);
        // accounts for case where lastEarn is before first checkpoint
        _currTs = ProtocolTimeLibrary.epochStart(Math.max(
            _currTs,
            ProtocolTimeLibrary.epochStart(cp0.timestamp)
        ));

        // get epochs between current epoch and first checkpoint in same epoch as last claim
        uint256 numEpochs = (ProtocolTimeLibrary.epochStart(block.timestamp) -
            _currTs) / DURATION;

        console.log("numEpochs", numEpochs);

        if (numEpochs > 0) {
            for (uint256 i = 0; i < numEpochs; i++) {
                console.log("currTs", _currTs);
                // get index of checkpoint at the start of this epoch
                _index = getPriorBalanceIndex(_owner, _currTs);
                // get checkpoint in this epoch
                cp0 = checkpoints[_owner][_index];
                
                // Ensure we're using a checkpoint from this epoch or earlier (not from a future epoch)
                // If checkpoint is from a future epoch, skip this epoch (shouldn't happen, but safety check)
                if (ProtocolTimeLibrary.epochStart(cp0.timestamp) > _currTs) {
                    _currTs += DURATION;
                    continue;
                }
                
                // Calculate the reward for this epoch: convert balance (shares) to assets
                // Use the balance at the start of the epoch (cp0._balances represents shares at that time)
                // epochReward represents the total asset value the user is entitled to for this epoch
                // based on their share balance and the assets unlocked in this epoch
                uint256 epochReward = _convertToAssets(cp0._balances, Math.Rounding.Floor, _currTs);
                console.log("cp0._balances", cp0._balances);
                console.log("cp0.timestamp", cp0.timestamp);
                console.log("epochReward", epochReward);
                console.log("checkpoints[_owner][_currTs].alreadyClaimed", checkpoints[_owner][_currTs].alreadyClaimed);

                
                // Get what was already claimed for this epoch
                uint256 alreadyClaimed = checkpoints[_owner][_currTs].alreadyClaimed;
                console.log("alreadyClaimed", alreadyClaimed);  
                console.log("epochReward", epochReward);
                
                // Calculate the incremental reward for this epoch
                // If this is the first time calculating for this epoch, newReward = epochReward
                // If we're recalculating (e.g., because time passed and totalAssetsUnlocked increased),
                // newReward = the incremental increase
                uint256 newReward = epochReward > alreadyClaimed ? epochReward - alreadyClaimed : 0;
                console.log("newReward", newReward);
                console.log("----------------");
                
                // If we had previously calculated rewards for this epoch, subtract the old value
                // to avoid double counting, then add the new total
                if (alreadyClaimed > 0) {
                    reward -= alreadyClaimed;
                }
                
                // Update the claimed amount for this epoch to the new total
                // This tracks the cumulative reward entitlement for this epoch
                checkpoints[_owner][_currTs].alreadyClaimed = epochReward;
                
                console.log("epochReward", epochReward);
                console.log("alreadyClaimed", alreadyClaimed);
                console.log("newReward", newReward);
                // Add the new total reward (we already subtracted the old value above if needed)
                reward += epochReward;
                
                _currTs += DURATION;
            }
        }

        return reward;
    }

    function claimDebtRewards(address _owner) external returns (uint256) {
        require(msg.sender == vault, "Only vault can claim debt rewards");
        return _claimDebtRewards(_owner);
    }

    function _claimDebtRewards(address _owner) internal returns (uint256) {
        
        // Calculate earned rewards (this updates tokenClaimedPerEpoch for each epoch)
        // earned() will calculate from lastEarn to now, and update tokenClaimedPerEpoch
        // If lastEarn is 0, it will calculate from the first checkpoint
        uint256 _reward = earned(address(this), _owner);
        
        console.log("_____", _reward);
        
        // Update lastEarn to current timestamp to prevent double-counting in future calls
        // This ensures that the next time earned() is called, it will only calculate rewards
        // from this point forward, not from the old lastEarn timestamp
        lastEarn[address(this)][_owner] = block.timestamp;

        emit ClaimRewards(_owner, address(this), _reward);
        return _reward;
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
        console.log("WRITING SUPPLY CHECKPOINT", _to, newBalance);

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
        console.log("+++++ratio", ratio);
        if (ratio > 0 && ratio < 10000) {
            uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

            // Now calculate the new vault balance to maintain the ratio
            uint256 newVaultBalance = (totalAssetsPerEpoch[currentEpoch] * ratio) / (10000 - ratio);
            console.log("+++++newVaultBalance", newVaultBalance);
            console.log("totalAssetsPerEpoch[currentEpoch]", totalAssetsPerEpoch[currentEpoch]);
            console.log("ratio", ratio);
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
        console.log("epoch", epoch);
        // If totalSupply is 0, there's no supply in this epoch, so rewards should be 0
        if (epochSupply == 0) {
            return 0;
        }

        // For reward calculation, use totalAssetsUnlocked which returns:
        // - Full assets for past epochs
        // - Prorated assets for current epoch (based on elapsed time)
        uint256 assetsUnlocked = totalAssetsUnlocked(epoch);
        console.log("++++totalAssetsUnlocked(epoch)", assetsUnlocked);
        console.log("epochSupply", epochSupply);
        return shares.mulDiv(assetsUnlocked + 1, epochSupply + 10 ** _decimalsOffset(), rounding);
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