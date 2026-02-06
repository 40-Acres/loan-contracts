// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.27;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProtocolTimeLibrary} from "../../../libraries/ProtocolTimeLibrary.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IFeeCalculator} from "./IFeeCalculator.sol";
import {FeeCalculator} from "./FeeCalculator.sol";
import {IPortfolioFactory} from "../../../interfaces/IPortfolioFactory.sol";
import {ILendingPool} from "../../../interfaces/ILendingPool.sol";

/**
 * @title DynamicFeesVault
 * @notice ERC4626 vault with integrated debt tracking and dynamic fee distribution
 * @dev Combines vault functionality with debt token accounting for reward distribution
 * @dev Uses epoch-based reward vesting with swappable fee calculators
 */
contract DynamicFeesVault is Initializable, ERC4626Upgradeable, UUPSUpgradeable, Ownable2StepUpgradeable, ILendingPool {
    using Math for uint256;
    using SafeERC20 for IERC20;

    // ============ Constants ============
    uint256 public constant DURATION = 7 days;
    uint256 public constant MAX_EPOCH_ITERATIONS = 52; // ~1 year of weeks
    uint256 public constant PRECISION = 1e18;

    // ============ Events ============
    event Synced(uint256 indexed epoch, uint256 totalLoanedAssets, uint256 principalRepaid);
    event Paused(address indexed pauser);
    event Unpaused(address indexed unpauser);
    event PauserAdded(address indexed pauser);
    event PauserRemoved(address indexed pauser);
    event DebtBalanceUpdated(address indexed borrower, uint256 oldBalance, uint256 newBalance, uint256 rewardsApplied);
    event RewardsMinted(address indexed to, uint256 amount);
    event FeeCalculatorUpdated(address indexed oldCalculator, address indexed newCalculator);
    event ExcessRewardsPaid(address indexed borrower, uint256 amount);
    event DebtTransferred(address indexed from, address indexed to, uint256 amount);

    // ============ Errors ============
    error ContractPaused();
    error NotPauser();
    error AlreadyPauser();
    error NotAPauser();
    error InvalidReward();
    error ZeroAmount();
    error ZeroAddress();

    // ============ ERC-7201 Namespaced Storage ============
    /// @custom:storage-location erc7201:dynamicfeesvault.storage
    struct DynamicFeesVaultStorage {
        // Vault state
        uint256 totalLoanedAssets;
        mapping(address => uint256) debtBalance;
        uint256 originationFeeBasisPoints;
        uint256 settlementCheckpointEpoch;
        uint256 principalRepaidAtCheckpoint;
        address portfolioFactory;
        bool paused;
        mapping(address => bool) pausers;

        // Fee calculator
        address feeCalculator;

        // Track vested rewards that have been applied to individual user debts
        // This accumulates incrementally as users sync, avoiding need to iterate all users
        uint256 totalVestedRewardsApplied;

        // Debt token state
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

    // keccak256(abi.encode(uint256(keccak256("dynamicfeesvault.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION =
        0x9a0c9d8ec1d9f8b4c5e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b200;

    function _getStorage() private pure returns (DynamicFeesVaultStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }

    // ============ Constructor ============
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============
    function initialize(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _portfolioFactory
    ) public initializer {
        if (_asset == address(0)) revert ZeroAddress();
        if (_portfolioFactory == address(0)) revert ZeroAddress();

        __ERC4626_init(ERC20(_asset));
        __ERC20_init(_name, _symbol);
        __UUPSUpgradeable_init();
        __Ownable2Step_init();
        _transferOwnership(msg.sender);

        DynamicFeesVaultStorage storage $ = _getStorage();
        $.portfolioFactory = _portfolioFactory;

        // Deploy the default fee calculator
        FeeCalculator feeCalc = new FeeCalculator();
        $.feeCalculator = address(feeCalc);
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
        DynamicFeesVaultStorage storage $ = _getStorage();
        address oldCalculator = $.feeCalculator;
        $.feeCalculator = _newFeeCalculator;
        emit FeeCalculatorUpdated(oldCalculator, _newFeeCalculator);
    }

    // ============ View Functions ============
    function feeCalculator() public view returns (address) {
        return _getStorage().feeCalculator;
    }

    function totalLoanedAssets() public view returns (uint256) {
        return _getStorage().totalLoanedAssets;
    }

    function getDebtBalance(address borrower) public view returns (uint256) {
        return _getStorage().debtBalance[borrower];
    }

    function paused() public view returns (bool) {
        return _getStorage().paused;
    }

    function isPauser(address account) public view returns (bool) {
        return _getStorage().pausers[account];
    }

    function getSettlementCheckpoint() public view returns (uint256 checkpointEpoch, uint256 principalRepaidAtCheckpoint) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        return ($.settlementCheckpointEpoch, $.principalRepaidAtCheckpoint);
    }

    // ============ Debt Token View Functions ============
    function checkpoints(address _owner, uint256 _index) public view returns (uint256 epoch, uint256 balances) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        Checkpoint storage cp = $.checkpoints[_owner][_index];
        return (cp._epoch, cp._balances);
    }

    function numCheckpoints(address _owner) public view returns (uint256) {
        return _getStorage().numCheckpoints[_owner];
    }

    function rewardTotalAssetsPerEpoch(uint256 _epoch) public view returns (uint256) {
        return _getStorage().totalAssetsPerEpoch[_epoch];
    }

    function rewardTotalSupplyPerEpoch(uint256 _epoch) public view returns (uint256) {
        return _getStorage().totalSupplyPerEpoch[_epoch];
    }

    function supplyCheckpoints(uint256 _index) public view returns (uint256 epoch, uint256 supply) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        SupplyCheckpoint storage sc = $.supplyCheckpoints[_index];
        return (sc._epoch, sc._supply);
    }

    function supplyNumCheckpoints() public view returns (uint256) {
        return _getStorage().supplyNumCheckpoints;
    }

    function tokenClaimedPerEpoch(address _owner, uint256 _epoch) public view returns (uint256) {
        return _getStorage().tokenClaimedPerEpoch[_owner][_epoch];
    }

    function rewardTotalSupply() public view returns (uint256) {
        return _getStorage().totalSupplyPerEpoch[ProtocolTimeLibrary.epochStart(block.timestamp)];
    }

    function rewardTotalSupply(uint256 epoch) public view returns (uint256) {
        return _getStorage().totalSupplyPerEpoch[epoch];
    }

    function rewardTotalAssets() public view returns (uint256) {
        return _getStorage().totalAssetsPerEpoch[ProtocolTimeLibrary.epochStart(block.timestamp)];
    }

    function rewardTotalAssets(uint256 epoch) public view returns (uint256) {
        epoch = ProtocolTimeLibrary.epochStart(epoch);
        uint256 currentTimestamp = block.timestamp;
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(currentTimestamp);

        if (currentEpoch == epoch) {
            DynamicFeesVaultStorage storage $ = _getStorage();
            uint256 assets = $.totalAssetsPerEpoch[epoch];
            uint256 duration = ProtocolTimeLibrary.epochNext(epoch) - epoch;
            uint256 elapsed = currentTimestamp - epoch;
            uint256 prorated = (assets * elapsed) / duration;
            return prorated;
        }
        return _getStorage().totalAssetsPerEpoch[epoch];
    }

    // ============ ERC4626 Override ============
    function totalAssets() public view override returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();

        // Two components reduce the effective debt:
        // 1. totalVestedRewardsApplied - rewards already applied to individual user debts
        // 2. Pending vesting - rewards that could be applied but users haven't synced yet
        //
        // Total effective reduction = totalVestedRewardsApplied + pending vesting
        // Since pending vesting = currentPrincipalRepaid - totalVestedRewardsApplied,
        // Total reduction = currentPrincipalRepaid
        uint256 currentPrincipalRepaid = _getPrincipalRepaid();

        uint256 adjustedTotalLoanedAssets = $.totalLoanedAssets > currentPrincipalRepaid
            ? $.totalLoanedAssets - currentPrincipalRepaid
            : 0;

        uint256 lenderPremiumCurrentEpoch = _previewLenderPremiumUnlocked();
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);

        return IERC20(asset()).balanceOf(address(this)) + adjustedTotalLoanedAssets
            - $.totalAssetsPerEpoch[currentEpoch] + lenderPremiumCurrentEpoch;
    }

    // ============ Fee Calculator Functions ============
    function getCurrentVaultRatioBps() public view returns (uint256) {
        return getVaultRatioBps(getUtilizationPercent());
    }

    function getVaultRatioBps(uint256 utilizationBps) public view returns (uint256 rate) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        return IFeeCalculator($.feeCalculator).getVaultRatioBps(utilizationBps);
    }

    function getUtilizationPercent() public view returns (uint256) {
        uint256 total = totalAssets();
        if (total == 0) return 0;
        DynamicFeesVaultStorage storage $ = _getStorage();
        return ($.totalLoanedAssets * 10000) / total;
    }

    // ============ Checkpoint Functions ============
    function getPriorBalanceIndex(address _owner, uint256 _timestamp) public view returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
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

    function _getCurrentRewardBalance(address _owner) internal view returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 nCheckpoints = $.numCheckpoints[_owner];
        if (nCheckpoints == 0) {
            return 0;
        }
        return $.checkpoints[_owner][nCheckpoints - 1]._balances;
    }

    function _writeCheckpoint(address _owner, uint256 _balance) internal {
        DynamicFeesVaultStorage storage $ = _getStorage();
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
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 _nCheckPoints = $.supplyNumCheckpoints;
        uint256 _timestamp = ProtocolTimeLibrary.epochStart(block.timestamp);

        if (_nCheckPoints > 0 && $.supplyCheckpoints[_nCheckPoints - 1]._epoch == _timestamp) {
            $.supplyCheckpoints[_nCheckPoints - 1] = SupplyCheckpoint(_timestamp, rewardTotalSupply());
        } else {
            $.supplyCheckpoints[_nCheckPoints] = SupplyCheckpoint(_timestamp, rewardTotalSupply());
            $.supplyNumCheckpoints = _nCheckPoints + 1;
        }
    }

    // ============ Reward Functions ============
    function _getReward(address _owner) internal returns (uint256) {
        return _earned(_owner);
    }

    function lenderPremiumUnlockedThisEpoch() public returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        _earned(address(this));
        uint256 _epoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        return $.tokenClaimedPerEpoch[address(this)][_epoch];
    }

    function debtRepaidThisEpoch() public returns (uint256) {
        uint256 _epoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        return rewardTotalAssets(_epoch) - lenderPremiumUnlockedThisEpoch();
    }

    function _earned(address _owner) internal returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
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
                _supply = Math.max(rewardTotalSupply(epoch), 1);
                uint256 assetsUnlocked = rewardTotalAssets(epoch);

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

    // ============ Reward Mint Functions ============
    function _mintReward(address _to, uint256 _amount) internal {
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        uint256 currentBalance = _getCurrentRewardBalance(_to);

        // If user has no checkpoints, create one at previous epoch so they can
        // claim rewards for the current epoch (since _earned() looks for checkpoints
        // BEFORE each epoch to prevent gaming)
        bool createdPreviousCheckpoint = false;
        if ($.numCheckpoints[_to] == 0 && currentEpoch >= DURATION) {
            uint256 previousEpoch = currentEpoch - DURATION;
            $.checkpoints[_to][0] = Checkpoint(previousEpoch, _amount);
            $.numCheckpoints[_to] = 1;
            createdPreviousCheckpoint = true;
        }

        $.totalAssetsPerEpoch[currentEpoch] += _amount;

        // Only add _amount if we didn't already account for it in the previous epoch checkpoint
        uint256 newBalance = createdPreviousCheckpoint ? _amount : currentBalance + _amount;

        _writeCheckpoint(_to, newBalance);
        _rebalance();

        emit RewardsMinted(_to, _amount);
    }

    function _rebalance() internal {
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 utilizationBps = getUtilizationPercent();
        uint256 ratio = getVaultRatioBps(utilizationBps);
        if (ratio > 0 && ratio < 10000) {
            uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
            uint256 newVaultBalance = ($.totalAssetsPerEpoch[currentEpoch] * ratio) / (10000 - ratio);
            $.totalSupplyPerEpoch[currentEpoch] = $.totalAssetsPerEpoch[currentEpoch] + newVaultBalance;
            _writeCheckpoint(address(this), newVaultBalance);
            _writeSupplyCheckpoint();
        }
    }

    // ============ Internal Helper Functions ============
    function _previewLenderPremiumUnlocked() internal view returns (uint256) {
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        DynamicFeesVaultStorage storage $ = _getStorage();
        return $.tokenClaimedPerEpoch[address(this)][currentEpoch];
    }

    function assetsUnlockedThisEpoch() public view returns (uint256) {
        return rewardTotalAssets(ProtocolTimeLibrary.epochStart(block.timestamp));
    }

    function _getPrincipalRepaid() internal view returns (uint256) {
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 checkpointEpoch = $.settlementCheckpointEpoch;
        uint256 totalPrincipalRepaid = 0;

        uint256 startEpoch = checkpointEpoch > 0 ? checkpointEpoch : currentEpoch;

        uint256 iterations = 0;
        for (uint256 epoch = startEpoch; epoch <= currentEpoch && iterations < MAX_EPOCH_ITERATIONS; epoch += ProtocolTimeLibrary.WEEK) {
            iterations++;
            uint256 assetsUnlocked = rewardTotalAssets(epoch);
            if (assetsUnlocked == 0) continue;

            uint256 lenderPremium;
            if (epoch == currentEpoch) {
                lenderPremium = _previewLenderPremiumUnlocked();
            } else {
                lenderPremium = $.tokenClaimedPerEpoch[address(this)][epoch];
            }

            uint256 principalRepaid = assetsUnlocked > lenderPremium ? assetsUnlocked - lenderPremium : 0;
            totalPrincipalRepaid += principalRepaid;
        }

        return totalPrincipalRepaid;
    }

    function _updateSettlementCheckpoint() internal {
        DynamicFeesVaultStorage storage $ = _getStorage();
        _getReward(address(this));

        // totalLoanedAssets is NOT reduced here - it's only reduced on explicit repayment
        // totalAssets() calculates the adjustment view-only using principalRepaid
        uint256 currentPrincipalRepaid = _getPrincipalRepaid();
        $.principalRepaidAtCheckpoint = currentPrincipalRepaid;
        $.settlementCheckpointEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
    }

    function _updateUserDebtBalance(address borrower) internal {
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 earned = _getReward(borrower);
        uint256 oldDebtBalance = $.debtBalance[borrower];

        if (earned > 0) {
            // Calculate actual debt reduction (capped at current balance)
            uint256 debtReduction = earned > oldDebtBalance ? oldDebtBalance : earned;

            if (earned > oldDebtBalance) {
                // Rewards exceed debt - clear debt and transfer excess to borrower
                uint256 excess = earned - oldDebtBalance;
                $.debtBalance[borrower] = 0;
                IERC20(asset()).safeTransfer(borrower, excess);
                emit ExcessRewardsPaid(borrower, excess);
            } else {
                // Partial repayment - reduce debt by earned amount
                $.debtBalance[borrower] -= earned;
            }

            // Track vested rewards applied to individual debts
            // This allows totalAssets() to calculate correct global debt without iterating all users
            $.totalVestedRewardsApplied += debtReduction;

            emit DebtBalanceUpdated(borrower, oldDebtBalance, $.debtBalance[borrower], earned);
        }

        _rebalance();
    }

    // ============ Core Vault Functions ============
    function borrow(uint256 amount) external onlyPortfolio whenNotPaused {
        _updateSettlementCheckpoint();
        _updateUserDebtBalance(msg.sender);

        DynamicFeesVaultStorage storage $ = _getStorage();

        uint256 total = totalAssets();
        uint256 postBorrowLoaned = $.totalLoanedAssets + amount;
        uint256 postBorrowUtilization = total > 0 ? (postBorrowLoaned * 10000) / total : 0;
        require(postBorrowUtilization < 8000, "Borrow would exceed 80% utilization");

        IERC20(asset()).safeTransfer(msg.sender, amount);
        $.debtBalance[msg.sender] += amount;
        $.totalLoanedAssets += amount;
        _updateUserDebtBalance(msg.sender);
        _updateSettlementCheckpoint();
    }

    function repay(uint256 amount) external whenNotPaused {
        _updateSettlementCheckpoint();
        _updateUserDebtBalance(msg.sender);
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 userDebtBalance = $.debtBalance[msg.sender];
        uint256 amountToRepay = userDebtBalance < amount ? userDebtBalance : amount;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amountToRepay);
        $.totalLoanedAssets -= amountToRepay;
        $.debtBalance[msg.sender] -= amountToRepay;
        _updateUserDebtBalance(msg.sender);
        _updateSettlementCheckpoint();
    }

    function repayWithRewards(uint256 amount) external whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        _updateSettlementCheckpoint();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        _mintReward(msg.sender, amount);
        _updateUserDebtBalance(msg.sender);
        _updateSettlementCheckpoint();
    }

    // ============ ILendingPool Implementation ============
    /**
     * @notice Borrow funds from the vault on behalf of a portfolio account
     * @param amount The amount to borrow
     * @return originationFee Always returns 0 for DynamicFeesVault (no origination fees)
     */
    function borrowFromPortfolio(uint256 amount) external onlyPortfolio whenNotPaused returns (uint256 originationFee) {
        _updateSettlementCheckpoint();
        _updateUserDebtBalance(msg.sender);

        DynamicFeesVaultStorage storage $ = _getStorage();

        uint256 total = totalAssets();
        uint256 postBorrowLoaned = $.totalLoanedAssets + amount;
        uint256 postBorrowUtilization = total > 0 ? (postBorrowLoaned * 10000) / total : 0;
        require(postBorrowUtilization < 8000, "Borrow would exceed 80% utilization");

        IERC20(asset()).safeTransfer(msg.sender, amount);
        $.debtBalance[msg.sender] += amount;
        $.totalLoanedAssets += amount;
        _updateUserDebtBalance(msg.sender);
        _updateSettlementCheckpoint();

        return 0; // No origination fee for DynamicFeesVault
    }

    /**
     * @notice Repay funds to the vault from a portfolio account
     * @param totalPayment The total payment amount
     * @param feesToPay The portion of payment that goes to protocol fees (sent to owner)
     */
    function payFromPortfolio(uint256 totalPayment, uint256 feesToPay) external whenNotPaused {
        _updateSettlementCheckpoint();
        _updateUserDebtBalance(msg.sender);

        DynamicFeesVaultStorage storage $ = _getStorage();

        // Handle unpaid fees first - transfer to protocol owner
        if (feesToPay > 0) {
            IERC20(asset()).safeTransferFrom(msg.sender, owner(), feesToPay);
        }

        // Transfer remaining amount to vault (principal repayment)
        uint256 balanceToPay = totalPayment - feesToPay;
        if (balanceToPay > 0) {
            uint256 userDebtBalance = $.debtBalance[msg.sender];
            uint256 amountToRepay = userDebtBalance < balanceToPay ? userDebtBalance : balanceToPay;

            IERC20(asset()).safeTransferFrom(msg.sender, address(this), amountToRepay);
            $.totalLoanedAssets -= amountToRepay;
            $.debtBalance[msg.sender] -= amountToRepay;
        }

        _updateUserDebtBalance(msg.sender);
        _updateSettlementCheckpoint();
    }

    /**
     * @notice Get the lending asset address
     * @return The address of the lending asset (same as ERC4626 asset)
     */
    function lendingAsset() external view returns (address) {
        return asset();
    }

    /**
     * @notice Get the vault address (this contract is both lending pool and vault)
     * @return The vault address (address(this))
     */
    function lendingVault() external view returns (address) {
        return address(this);
    }

    /**
     * @notice Get the total outstanding loaned assets
     * @return The total amount of assets currently loaned out
     */
    function activeAssets() external view returns (uint256) {
        return _getStorage().totalLoanedAssets;
    }

    /**
     * @notice Get the total vested rewards that have been applied to individual user debts
     * @return The cumulative vested rewards applied
     */
    function totalVestedRewardsApplied() external view returns (uint256) {
        return _getStorage().totalVestedRewardsApplied;
    }

    function updateUserDebtBalance(address borrower) public {
        _updateSettlementCheckpoint();
        _updateUserDebtBalance(borrower);
        _updateSettlementCheckpoint();
    }

    /**
     * @notice Transfer debt from one borrower to another
     * @param from The address to transfer debt from
     * @param to The address to transfer debt to
     * @param amount The amount of debt to transfer
     */
    function transferDebt(address from, address to, uint256 amount) external onlyPortfolio {
        _updateSettlementCheckpoint();
        _updateUserDebtBalance(from);
        _updateUserDebtBalance(to);

        DynamicFeesVaultStorage storage $ = _getStorage();

        uint256 fromBalance = $.debtBalance[from];
        uint256 transferAmount = amount > fromBalance ? fromBalance : amount;

        $.debtBalance[from] -= transferAmount;
        $.debtBalance[to] += transferAmount;

        _updateUserDebtBalance(from);
        _updateUserDebtBalance(to);
        _updateSettlementCheckpoint();

        emit DebtTransferred(from, to, transferAmount);
    }

    function sync() public {
        _updateSettlementCheckpoint();
        DynamicFeesVaultStorage storage $ = _getStorage();
        emit Synced(
            ProtocolTimeLibrary.epochStart(block.timestamp),
            $.totalLoanedAssets,
            $.principalRepaidAtCheckpoint
        );
    }

    // ============ Pause Mechanism ============
    function pause() external {
        DynamicFeesVaultStorage storage $ = _getStorage();
        if (!$.pausers[msg.sender] && msg.sender != owner()) revert NotPauser();
        $.paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        DynamicFeesVaultStorage storage $ = _getStorage();
        $.paused = false;
        emit Unpaused(msg.sender);
    }

    function addPauser(address pauser) external onlyOwner {
        DynamicFeesVaultStorage storage $ = _getStorage();
        if ($.pausers[pauser]) revert AlreadyPauser();
        $.pausers[pauser] = true;
        emit PauserAdded(pauser);
    }

    function removePauser(address pauser) external onlyOwner {
        DynamicFeesVaultStorage storage $ = _getStorage();
        if (!$.pausers[pauser]) revert NotAPauser();
        $.pausers[pauser] = false;
        emit PauserRemoved(pauser);
    }

    modifier whenNotPaused() {
        DynamicFeesVaultStorage storage $ = _getStorage();
        if ($.paused) revert ContractPaused();
        _;
    }

    // ============ ERC4626 Overrides ============
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        DynamicFeesVaultStorage storage $ = _getStorage();
        if ($.paused) revert ContractPaused();

        _updateSettlementCheckpoint();
        super._deposit(caller, receiver, assets, shares);
        _rebalance();
    }

    function _withdraw(
        address caller,
        address receiver,
        address _owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        DynamicFeesVaultStorage storage $ = _getStorage();
        if ($.paused) revert ContractPaused();

        _updateSettlementCheckpoint();
        super._withdraw(caller, receiver, _owner, assets, shares);
        _rebalance();
    }

    // ============ Access Control ============
    modifier onlyPortfolio() {
        DynamicFeesVaultStorage storage $ = _getStorage();
        require(IPortfolioFactory($.portfolioFactory).isPortfolio(msg.sender), "Only portfolio can call this function");
        _;
    }
}
