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

/**
 * @title DebtToken
 * @notice Abstract contract for debt tokens
 * @dev This contract is used to track the lender premium and amount paid down to a borower's balance over time
 * @dev This is entirely used for accounting purposes, the payments are send to the vault and all assets are held there
 */
abstract contract DebtToken {

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
    
    /// @notice The percentage of total supply that should be held by the vault (in basis points, e.g., 8000 = 80%)
    /// @dev If vaultRatioBps is 20%, then vault should have 20% of the overall supply
    /// @dev The vault address is address(this) since the vault contract inherits from DebtToken
    uint256 public vaultRatioBps = 8000; // Default to 80% (8000 basis points)

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

    struct SupplyCheckpoint {
        uint256 timestamp;
        uint256 supply;
    }
    mapping(address => mapping(uint256 => Checkpoint)) public checkpoints;
    mapping(address => uint256) public numCheckpoints;
    mapping(uint256 => SupplyCheckpoint) public supplyCheckpoints;
    uint256 public supplyNumCheckpoints;

    

    mapping(uint256 => uint256) public totalSupplyPerEpoch;





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
        uint256 newBalance = currentBalance + _amount;

        // Update balance checkpoint
        _writeCheckpoint(_to, newBalance);

        // Update total supply per epoch
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        totalSupplyPerEpoch[currentEpoch] += _amount;

        _rebalance();

        // Update supply checkpoint
        _writeSupplyCheckpoint();

        emit Mint(_to, _amount);
    }


    function _rebalance() internal {
        if (vaultRatioBps > 0 && vaultRatioBps < 10000) {
            uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
            uint256 vaultBalance = _getCurrentBalance(address(this));

            // Remove the vault balance from the total supply only if it exists in this epoch
            // Check if vault has a checkpoint in the current epoch
            uint256 vaultCheckpoints = numCheckpoints[address(this)];
            if (vaultCheckpoints > 0) {
                uint256 lastCheckpointIndex = vaultCheckpoints - 1;
                uint256 lastCheckpointEpoch = ProtocolTimeLibrary.epochStart(
                    checkpoints[address(this)][lastCheckpointIndex].timestamp
                );
                
                // Only subtract vault balance if it's from the current epoch
                if (lastCheckpointEpoch == currentEpoch && vaultBalance <= totalSupplyPerEpoch[currentEpoch]) {
                    totalSupplyPerEpoch[currentEpoch] -= vaultBalance;
                }
            }

            // Now calculate the new vault balance to maintain the ratio
            // newVaultBalance = userSupply * vaultRatioBps / (10000 - vaultRatioBps)
            uint256 newVaultBalance = (totalSupplyPerEpoch[currentEpoch] * vaultRatioBps) / (10000 - vaultRatioBps);
            
            totalSupplyPerEpoch[currentEpoch] += newVaultBalance;
            _writeCheckpoint(address(this), newVaultBalance);
        }
    }
    /**
     * @notice Sets the vault ratio in basis points (e.g., 2000 = 20%, 8000 = 80%)
     * @dev Only callable by the authorized address
     * @dev The vault address is always address(this) since the vault contract inherits from DebtToken
     * @param _vaultRatioBps The vault ratio in basis points (must be between 0 and 10000)
     */
    function setVaultRatioBps(uint256 _vaultRatioBps) external {
        if (msg.sender != authorized) revert NotAuthorized();
        if (_vaultRatioBps >= 10000) revert InvalidReward(); // Ratio cannot be 100% or more
        vaultRatioBps = _vaultRatioBps;
    }


    // ERC4626 Implementations
    function _tryGetAssetDecimals(IERC20 asset_) private view returns (bool ok, uint8 assetDecimals) {
        Memory.Pointer ptr = Memory.getFreeMemoryPointer();
        (bool success, bytes32 returnedDecimals, ) = LowLevelCall.staticcallReturn64Bytes(
            address(asset_),
            abi.encodeCall(IERC20Metadata.decimals, ())
        );
        Memory.setFreeMemoryPointer(ptr);

        return
            (success && LowLevelCall.returnDataSize() >= 32 && uint256(returnedDecimals) <= type(uint8).max)
                ? (true, uint8(uint256(returnedDecimals)))
                : (false, 0);
    }

    /**
     * @dev Decimals are computed by adding the decimal offset on top of the underlying asset's decimals. This
     * "original" value is cached during construction of the vault contract. If this read operation fails (e.g., the
     * asset has not been created yet), a default of 18 is used to represent the underlying asset's decimals.
     *
     * See {IERC20Metadata-decimals}.
     */
    function decimals() public view virtual override(IERC20Metadata, ERC20) returns (uint8) {
        return _underlyingDecimals + _decimalsOffset();
    }

    /// @inheritdoc IERC4626
    function asset() public view virtual returns (address) {
        return address(_asset);
    }

    /// @inheritdoc IERC4626
    function totalAssets() public view virtual returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @inheritdoc IERC4626
    function convertToShares(uint256 assets) public view virtual returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    function convertToAssets(uint256 shares) public view virtual returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    function maxDeposit(address) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc IERC4626
    function maxMint(address) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc IERC4626
    function maxWithdraw(address owner) public view virtual returns (uint256) {
        return previewRedeem(maxRedeem(owner));
    }

    /// @inheritdoc IERC4626
    function maxRedeem(address owner) public view virtual returns (uint256) {
        return balanceOf(owner);
    }

    /// @inheritdoc IERC4626
    function previewDeposit(uint256 assets) public view virtual returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    function previewMint(uint256 shares) public view virtual returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    function previewWithdraw(uint256 assets) public view virtual returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    function previewRedeem(uint256 shares) public view virtual returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    function deposit(uint256 assets, address receiver) public virtual returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);

        return shares;
    }

    /// @inheritdoc IERC4626
    function mint(uint256 shares, address receiver) public virtual returns (uint256) {
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }

        uint256 assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);

        return assets;
    }

    /// @inheritdoc IERC4626
    function withdraw(uint256 assets, address receiver, address owner) public virtual returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return shares;
    }

    /// @inheritdoc IERC4626
    function redeem(uint256 shares, address receiver, address owner) public virtual returns (uint256) {
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        uint256 assets = previewRedeem(shares);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return assets;
    }

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view virtual returns (uint256) {
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view virtual returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    }

    /**
     * @dev Deposit/mint common workflow.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual {
        // If asset() is ERC-777, `transferFrom` can trigger a reentrancy BEFORE the transfer happens through the
        // `tokensToSend` hook. On the other hand, the `tokenReceived` hook, that is triggered after the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer before we mint so that any reentrancy would happen before the
        // assets are transferred and before the shares are minted, which is a valid state.
        // slither-disable-next-line reentrancy-no-eth
        _transferIn(caller, assets);
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Withdraw/redeem common workflow.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // If asset() is ERC-777, `transfer` can trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // shares are burned and after the assets are transferred, which is a valid state.
        _burn(owner, shares);
        _transferOut(receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev Performs a transfer in of underlying assets. The default implementation uses `SafeERC20`. Used by {_deposit}.
    function _transferIn(address from, uint256 assets) internal virtual {
        SafeERC20.safeTransferFrom(IERC20(asset()), from, address(this), assets);
    }

    /// @dev Performs a transfer out of underlying assets. The default implementation uses `SafeERC20`. Used by {_withdraw}.
    function _transferOut(address to, uint256 assets) internal virtual {
        SafeERC20.safeTransfer(IERC20(asset()), to, assets);
    }

    function _decimalsOffset() internal view virtual returns (uint8) {
        return 0;
    }
}