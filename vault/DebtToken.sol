// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.27;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ProtocolTimeLibrary} from "../src/libraries/ProtocolTimeLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IFeeCalculator} from "./IFeeCalculator.sol";

interface IDynamicFeesVault {
    function decreaseTotalLoanedAssets(uint256 amount) external;
    function getUtilizationPercent() external view returns (uint256);
}

/**
 * @title DebtToken
 * @notice Upgradeable contract for tracking debt token rewards and fee distribution
 * @dev This contract is used to track the lender premium and amount paid down to a borrower's balance over time
 * @dev This is entirely used for accounting purposes, the payments are sent to the vault and all assets are held there
 * @dev Uses UUPS upgradeability pattern and supports swappable fee calculators
 */
contract DebtToken is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    using Math for uint256;

    // ============ Errors ============
    error InvalidReward();
    error NotAuthorized();
    error ZeroAmount();
    error ZeroAddress();

    // ============ Events ============
    event Mint(address indexed to, uint256 amount);
    event FeeCalculatorUpdated(address indexed oldCalculator, address indexed newCalculator);

    // ============ Constants ============
    uint256 public constant DURATION = 7 days;
    uint256 public constant MAX_EPOCH_ITERATIONS = 52; // ~1 year of weeks
    uint256 public constant PRECISION = 1e18;

    // ============ ERC-7201 Namespaced Storage ============
    /// @custom:storage-location erc7201:debttoken.storage
    struct DebtTokenStorage {
        address vault;
        address feeCalculator;
        mapping(address => mapping(uint256 => Checkpoint)) checkpoints;
        mapping(address => uint256) numCheckpoints;
        mapping(uint256 => uint256) totalAssetsPerEpoch;
        mapping(uint256 => uint256) totalSupplyPerEpoch;
        mapping(uint256 => SupplyCheckpoint) supplyCheckpoints;
        uint256 supplyNumCheckpoints;
        mapping(address => mapping(uint256 => uint256)) tokenClaimedPerEpoch;
    }

    struct Checkpoint {
        uint256 _epoch;
        uint256 _balances;
    }

    struct SupplyCheckpoint {
        uint256 _epoch;
        uint256 _supply;
    }

    // keccak256(abi.encode(uint256(keccak256("debttoken.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DEBT_TOKEN_STORAGE_LOCATION =
        0x8a0c9d8ec1d9f8b4c5e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b200;

    function _getDebtTokenStorage() private pure returns (DebtTokenStorage storage $) {
        assembly {
            $.slot := DEBT_TOKEN_STORAGE_LOCATION
        }
    }

    // ============ Constructor ============
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============
    /**
     * @notice Initializes the DebtToken contract
     * @param _vault The vault address that this debt token is associated with
     * @param _feeCalculator The initial fee calculator contract address
     * @param _owner The owner of this contract
     */
    function initialize(address _vault, address _feeCalculator, address _owner) public initializer {
        if (_vault == address(0)) revert ZeroAddress();
        if (_feeCalculator == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        __UUPSUpgradeable_init();
        __Ownable2Step_init();
        _transferOwnership(_owner);

        DebtTokenStorage storage $ = _getDebtTokenStorage();
        $.vault = _vault;
        $.feeCalculator = _feeCalculator;
    }

    // ============ UUPS Authorization ============
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ============ Admin Functions ============
    /**
     * @notice Updates the fee calculator contract
     * @param _newFeeCalculator The new fee calculator address
     */
    function setFeeCalculator(address _newFeeCalculator) external onlyOwner {
        if (_newFeeCalculator == address(0)) revert ZeroAddress();
        DebtTokenStorage storage $ = _getDebtTokenStorage();
        address oldCalculator = $.feeCalculator;
        $.feeCalculator = _newFeeCalculator;
        emit FeeCalculatorUpdated(oldCalculator, _newFeeCalculator);
    }

    // ============ View Functions ============
    function vault() public view returns (address) {
        return _getDebtTokenStorage().vault;
    }

    function feeCalculator() public view returns (address) {
        return _getDebtTokenStorage().feeCalculator;
    }

    function checkpoints(address _owner, uint256 _index) public view returns (uint256 epoch, uint256 balances) {
        DebtTokenStorage storage $ = _getDebtTokenStorage();
        Checkpoint storage cp = $.checkpoints[_owner][_index];
        return (cp._epoch, cp._balances);
    }

    function numCheckpoints(address _owner) public view returns (uint256) {
        return _getDebtTokenStorage().numCheckpoints[_owner];
    }

    function totalAssetsPerEpoch(uint256 _epoch) public view returns (uint256) {
        return _getDebtTokenStorage().totalAssetsPerEpoch[_epoch];
    }

    function totalSupplyPerEpoch(uint256 _epoch) public view returns (uint256) {
        return _getDebtTokenStorage().totalSupplyPerEpoch[_epoch];
    }

    function supplyCheckpoints(uint256 _index) public view returns (uint256 epoch, uint256 supply) {
        DebtTokenStorage storage $ = _getDebtTokenStorage();
        SupplyCheckpoint storage sc = $.supplyCheckpoints[_index];
        return (sc._epoch, sc._supply);
    }

    function supplyNumCheckpoints() public view returns (uint256) {
        return _getDebtTokenStorage().supplyNumCheckpoints;
    }

    function tokenClaimedPerEpoch(address _owner, uint256 _epoch) public view returns (uint256) {
        return _getDebtTokenStorage().tokenClaimedPerEpoch[_owner][_epoch];
    }

    /**
     * @notice Retrieves the index of the checkpoint valid at a specific timestamp for a given address
     * @param _owner The address for which to find the checkpoint
     * @param _timestamp The timestamp to query the balance at
     * @return The index of the checkpoint valid at the given timestamp
     */
    function getPriorBalanceIndex(address _owner, uint256 _timestamp) public view returns (uint256) {
        DebtTokenStorage storage $ = _getDebtTokenStorage();
        uint256 nCheckpoints = $.numCheckpoints[_owner];
        if (nCheckpoints == 0) {
            return 0;
        }

        uint256 epoch = ProtocolTimeLibrary.epochStart(_timestamp);

        if ($.checkpoints[_owner][nCheckpoints - 1]._epoch <= epoch) {
            return (nCheckpoints - 1);
        }

        if ($.checkpoints[_owner][0]._epoch > epoch) {
            return 0;
        }

        uint256 lower = 0;
        uint256 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint256 center = upper - (upper - lower) / 2;
            Checkpoint storage cp = $.checkpoints[_owner][center];
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

    function _getCurrentBalance(address _owner) internal view returns (uint256) {
        DebtTokenStorage storage $ = _getDebtTokenStorage();
        uint256 nCheckpoints = $.numCheckpoints[_owner];
        if (nCheckpoints == 0) {
            return 0;
        }
        return $.checkpoints[_owner][nCheckpoints - 1]._balances;
    }

    function _writeCheckpoint(address _owner, uint256 _balance) internal {
        DebtTokenStorage storage $ = _getDebtTokenStorage();
        uint256 _nCheckPoints = $.numCheckpoints[_owner];
        uint256 _timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);

        if (_nCheckPoints > 0 && $.checkpoints[_owner][_nCheckPoints - 1]._epoch == _timestamp) {
            $.checkpoints[_owner][_nCheckPoints - 1] = Checkpoint(_timestamp, _balance);
        } else {
            $.checkpoints[_owner][_nCheckPoints] = Checkpoint(_timestamp, _balance);
            $.numCheckpoints[_owner] = _nCheckPoints + 1;
        }
    }

    function _writeSupplyCheckpoint() internal {
        DebtTokenStorage storage $ = _getDebtTokenStorage();
        uint256 _nCheckPoints = $.supplyNumCheckpoints;
        uint256 _timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);

        if (_nCheckPoints > 0 && $.supplyCheckpoints[_nCheckPoints - 1]._epoch == _timestamp) {
            $.supplyCheckpoints[_nCheckPoints - 1] = SupplyCheckpoint(_timestamp, totalSupply());
        } else {
            $.supplyCheckpoints[_nCheckPoints] = SupplyCheckpoint(_timestamp, totalSupply());
            $.supplyNumCheckpoints = _nCheckPoints + 1;
        }
    }

    function totalSupply() public view returns (uint256) {
        return _getDebtTokenStorage().totalSupplyPerEpoch[ProtocolTimeLibrary.epochStart(block.timestamp)];
    }

    function totalSupply(uint256 epoch) public view returns (uint256) {
        return _getDebtTokenStorage().totalSupplyPerEpoch[epoch];
    }

    function totalAssets() public view returns (uint256) {
        return _getDebtTokenStorage().totalAssetsPerEpoch[ProtocolTimeLibrary.epochStart(block.timestamp)];
    }

    function totalAssets(uint256 epoch) public view returns (uint256) {
        epoch = ProtocolTimeLibrary.epochStart(epoch);
        uint256 currentTimestamp = block.timestamp;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(currentTimestamp);

        if (currentEpoch == epoch) {
            DebtTokenStorage storage $ = _getDebtTokenStorage();
            uint256 assets = $.totalAssetsPerEpoch[epoch];
            uint256 duration = ProtocolTimeLibrary.epochNext(epoch) - epoch;
            uint256 elapsed = currentTimestamp - epoch;
            uint256 prorated = (assets * elapsed) / duration;
            return prorated;
        }
        return _getDebtTokenStorage().totalAssetsPerEpoch[epoch];
    }

    // ============ Reward Functions ============
    function getReward(address _owner) external returns (uint256) {
        DebtTokenStorage storage $ = _getDebtTokenStorage();
        require(msg.sender == $.vault, "Only vault can get rewards");
        return _getReward(_owner);
    }

    function _getReward(address _owner) internal returns (uint256) {
        return earned(_owner);
    }

    function lenderPremiumUnlockedThisEpoch() public returns (uint256) {
        DebtTokenStorage storage $ = _getDebtTokenStorage();
        earned($.vault);
        uint256 _epoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        return $.tokenClaimedPerEpoch[$.vault][_epoch];
    }

    function debtRepaidThisEpoch() public returns (uint256) {
        uint256 _epoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        return totalAssets(_epoch) - lenderPremiumUnlockedThisEpoch();
    }

    function earned(address _owner) public returns (uint256) {
        DebtTokenStorage storage $ = _getDebtTokenStorage();
        if ($.numCheckpoints[_owner] == 0) {
            return 0;
        }

        uint256 reward = 0;
        uint256 _supply = 1;
        uint256 _currTs = ProtocolTimeLibrary.epochStart(block.timestamp);
        uint256 _index = getPriorBalanceIndex(_owner, _currTs);
        Checkpoint storage cp0 = $.checkpoints[_owner][_index];

        _currTs = Math.max(_currTs, ProtocolTimeLibrary.epochStart(cp0._epoch));

        uint256 currentEpochStart = ProtocolTimeLibrary.epochStart(block.timestamp);
        if (_currTs >= DURATION) {
            _currTs = _currTs - DURATION;
        }
        uint256 numEpochs = 0;
        if (currentEpochStart >= _currTs) {
            numEpochs = ((currentEpochStart - _currTs) / DURATION) + 1;
        }

        if (numEpochs > MAX_EPOCH_ITERATIONS) {
            numEpochs = MAX_EPOCH_ITERATIONS;
        }

        if (numEpochs > 0) {
            for (uint256 i = 0; i < numEpochs; i++) {
                uint256 epoch = _currTs;
                _supply = Math.max(totalSupply(epoch), 1);
                uint256 assetsUnlocked = totalAssets(epoch);

                if (assetsUnlocked == 0) {
                    _currTs += DURATION;
                    continue;
                }

                uint256 queryTimestamp = _currTs > 0 ? _currTs - 1 : _currTs;
                _index = getPriorBalanceIndex(_owner, queryTimestamp);

                uint256 nCheckpoints = $.numCheckpoints[_owner];
                if (_index >= nCheckpoints) {
                    _currTs += DURATION;
                    continue;
                }

                cp0 = $.checkpoints[_owner][_index];

                uint256 cpEpoch = ProtocolTimeLibrary.epochStart(cp0._epoch);
                while (cpEpoch >= _currTs && _index > 0) {
                    _index = _index - 1;
                    cp0 = $.checkpoints[_owner][_index];
                    cpEpoch = ProtocolTimeLibrary.epochStart(cp0._epoch);
                }

                uint256 epochReward = (cp0._balances * assetsUnlocked) / _supply;
                uint256 alreadyClaimed = $.tokenClaimedPerEpoch[_owner][epoch];
                uint256 newReward = epochReward > alreadyClaimed ? epochReward - alreadyClaimed : 0;

                $.tokenClaimedPerEpoch[_owner][epoch] = epochReward;
                reward += newReward;
                _currTs += DURATION;
            }
        }

        return reward;
    }

    // ============ Mint Functions ============
    function _mint(address _to, uint256 _amount) internal {
        DebtTokenStorage storage $ = _getDebtTokenStorage();
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        uint256 currentBalance = _getCurrentBalance(_to);

        $.totalAssetsPerEpoch[currentEpoch] += _amount;
        uint256 newBalance = currentBalance + _amount;

        _writeCheckpoint(_to, newBalance);
        _rebalance();

        emit Mint(_to, _amount);
    }

    function mint(address _to, uint256 _amount) external virtual {
        DebtTokenStorage storage $ = _getDebtTokenStorage();
        if (msg.sender != $.vault) revert NotAuthorized();
        if (_amount == 0) revert ZeroAmount();
        _mint(_to, _amount);
    }

    function rebalance() external {
        DebtTokenStorage storage $ = _getDebtTokenStorage();
        if (msg.sender != $.vault) revert NotAuthorized();
        _rebalance();
    }

    function _rebalance() internal {
        DebtTokenStorage storage $ = _getDebtTokenStorage();
        uint256 utilizationBps = IDynamicFeesVault($.vault).getUtilizationPercent();
        uint256 ratio = getVaultRatioBps(utilizationBps);
        if (ratio > 0 && ratio < 10000) {
            uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
            uint256 newVaultBalance = ($.totalAssetsPerEpoch[currentEpoch] * ratio) / (10000 - ratio);
            $.totalSupplyPerEpoch[currentEpoch] = $.totalAssetsPerEpoch[currentEpoch] + newVaultBalance;
            _writeCheckpoint($.vault, newVaultBalance);
            _writeSupplyCheckpoint();
        }
    }

    // ============ Fee Calculator Functions ============
    function getCurrentVaultRatioBps() public view virtual returns (uint256) {
        DebtTokenStorage storage $ = _getDebtTokenStorage();
        return getVaultRatioBps(IDynamicFeesVault($.vault).getUtilizationPercent());
    }

    /**
     * @notice Gets the vault ratio in basis points using the configured fee calculator
     * @param utilizationBps The utilization rate in basis points (e.g., 8000 = 80%)
     * @return rate The vault ratio in basis points
     */
    function getVaultRatioBps(uint256 utilizationBps) public view virtual returns (uint256 rate) {
        DebtTokenStorage storage $ = _getDebtTokenStorage();
        return IFeeCalculator($.feeCalculator).getVaultRatioBps(utilizationBps);
    }
}
