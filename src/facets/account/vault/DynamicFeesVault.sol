// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.27;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolTimeLibrary} from "../../../libraries/ProtocolTimeLibrary.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
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
contract DynamicFeesVault is Initializable, ERC4626Upgradeable, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable, ILendingPool {
    using SafeERC20 for IERC20;

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
    event ExcessRewardsEscrowed(address indexed borrower, uint256 amount);
    event EscrowClaimed(address indexed borrower, uint256 amount);
    event Borrowed(address indexed borrower, uint256 amount);
    event OriginationFeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event Repaid(address indexed borrower, uint256 amount, uint256 remainingDebt);
    event FeeAccrued(address indexed recipient, uint256 feeAssets, uint256 feeShares);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event Incentivized(address indexed from, uint256 amount, uint256 epoch);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ============ Errors ============
    error ContractPaused();
    error NotPauser();
    error AlreadyPauser();
    error NotAPauser();
    error ZeroAmount();
    error ZeroAddress();
    error FeeBpsTooHigh();
    error InvalidTreasury();

    // ============ Constants ============
    uint256 public constant MAX_FEE_BPS = 5000;

    /// @notice Snapshot of the values _processGlobalVesting would write at block.timestamp,
    ///         computed without mutating storage. Used by totalAssets() and
    ///         getEffectiveDebtBalance() so views reflect pending vesting.
    struct VestingSimulation {
        uint256 globalVested;
        uint256 lenderPremium;
        uint256 borrowerCredit;
        uint256 vestingEpochPremium;
        uint256 vestingEpochStart;
        uint256 totalUnsettledRewards;
        uint256 globalBorrowerPending;
        uint256 borrowerCreditPerRate;
    }

    // ============ ERC-7201 Namespaced Storage ============
    /// @custom:storage-location erc7201:dynamicfeesvault.storage
    struct DynamicFeesVaultStorage {
        // Vault state
        uint256 totalLoanedAssets;
        mapping(address => uint256) debtBalance;
        address portfolioFactory;
        bool paused;
        mapping(address => bool) pausers;

        // Fee calculator
        address feeCalculator;

        // Track vested rewards that have been applied to individual user debts
        uint256 totalVestedRewardsApplied;

        // Flash loan protection: block same-block deposit+withdraw
        mapping(address => uint256) lastDepositBlock;

        // Running sum of all debtBalance
        uint256 totalDebtBalance;

        // Epoch-based lender premium vesting
        uint256 currentEpochPremium;     // DEPRECATED — retained for ERC-7201 layout stability (deployed proxy)
        uint256 currentEpochStart;       // DEPRECATED — retained for ERC-7201 layout stability (deployed proxy)
        uint256 vestingEpochPremium;     // Premium from previous epoch (currently vesting linearly)
        uint256 vestingEpochStart;       // Epoch start time for vestingEpochPremium

        // Per-user reward streaming
        mapping(address => uint256) userRewardRate;        // USDC per second
        mapping(address => uint256) userPeriodFinish;      // epoch end when stream expires
        mapping(address => uint256) userLastSettledTime;   // last per-user settlement

        // Global reward vesting tracking
        uint256 activeEpochRate;         // sum of all active stream rates (USDC/sec)
        uint256 activeEpochEnd;          // epoch end for active streams
        uint256 globalLastUpdateTime;    // last global vesting computation
        uint256 totalUnsettledRewards;   // raw reward deposits not yet processed
        uint256 globalBorrowerPending;   // borrower portion computed globally, not yet applied per-user
        uint256 borrowerCreditPerRate;   // accumulated borrower credit per unit of stream rate, scaled by 1e18
        uint8 sharesDecimalsOffset;      // asset decimals used as virtual share offset for inflation attack prevention
        mapping(address => uint256) userBorrowerCreditPerRatePaid; // per-user snapshot of borrowerCreditPerRate
        mapping(uint256 => uint256) epochEndBorrowerCreditPerRate; // borrowerCreditPerRate frozen at each epoch boundary
        mapping(address => uint256) escrowedExcess; // excess rewards escrowed when transfer fails (e.g. USDC blacklist)
        uint256 __deprecated_maxUtilizationBps; // deprecated

        // Performance fee
        address feeRecipient;          // recipient of accrued fee shares; if zero, fee is disabled
        uint256 feeBps;                // basis points of realized interest minted as fee shares (cap MAX_FEE_BPS)
        uint256 lastTotalAssetsForFee; // snapshot of totalAssets() at last fee accrual; deltas count as interest

        uint256 escrowedExcessTotal;   // running sum of escrowedExcess[*] — liability deducted from totalAssets()

        // Treasury (recipient of protocol fees); zero falls back to owner()
        address treasury;

        uint256 originationFeeBps;
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
        address _portfolioFactory,
        address _feeRecipient,
        uint256 _feeBps
    ) public initializer {
        if (_asset == address(0)) revert ZeroAddress();
        if (_portfolioFactory == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_feeBps > MAX_FEE_BPS) revert FeeBpsTooHigh();

        __ERC4626_init(ERC20(_asset));
        __ERC20_init(_name, _symbol);
        __UUPSUpgradeable_init();
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        _transferOwnership(msg.sender);

        DynamicFeesVaultStorage storage $ = _getStorage();
        $.portfolioFactory = _portfolioFactory;
        $.sharesDecimalsOffset = ERC20(_asset).decimals();
        $.feeRecipient = _feeRecipient;
        $.feeBps = _feeBps;

        // Deploy the default fee calculator
        FeeCalculator feeCalc = new FeeCalculator();
        $.feeCalculator = address(feeCalc);

        // Snapshot baseline so first _accrueFee sees zero interest on an empty vault.
        $.lastTotalAssetsForFee = totalAssets();
    }

    // ============ UUPS Authorization ============
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ============ Admin Functions ============
    function setFeeCalculator(address _newFeeCalculator) external onlyOwner {
        if (_newFeeCalculator == address(0)) revert ZeroAddress();
        DynamicFeesVaultStorage storage $ = _getStorage();
        address oldCalculator = $.feeCalculator;
        $.feeCalculator = _newFeeCalculator;
        emit FeeCalculatorUpdated(oldCalculator, _newFeeCalculator);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        // Crystallize pending fee at the old recipient before swapping.
        _processGlobalVesting();
        DynamicFeesVaultStorage storage $ = _getStorage();
        address old = $.feeRecipient;
        $.feeRecipient = _feeRecipient;
        // If transitioning out of an off-state (recipient was zero), reset the
        // snapshot so totalAssets growth from the off-window is not retroactively
        // charged to LPs on the next accrual.
        if (old == address(0)) {
            $.lastTotalAssetsForFee = totalAssets();
        }
        emit FeeRecipientUpdated(old, _feeRecipient);
    }

    function setFeeBps(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert FeeBpsTooHigh();
        // Crystallize pending fee at the old rate before changing it.
        _processGlobalVesting();
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 old = $.feeBps;
        $.feeBps = _feeBps;
        // If transitioning out of an off-state (feeBps was zero), reset the
        // snapshot so totalAssets growth from the off-window is not retroactively
        // charged to LPs on the next accrual.
        if (old == 0 && _feeBps > 0) {
            $.lastTotalAssetsForFee = totalAssets();
        }
        emit FeeBpsUpdated(old, _feeBps);
    }

    function setOriginationFeeBps(uint256 _originationFeeBps) external onlyOwner {
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 old = $.originationFeeBps;
        $.originationFeeBps = _originationFeeBps;
        emit OriginationFeeBpsUpdated(old, _originationFeeBps);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidTreasury();
        DynamicFeesVaultStorage storage $ = _getStorage();
        address old = $.treasury;
        $.treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    // @dev Returns the configured treasury; falls back to owner() when unset.
    function getTreasury() public view returns (address) {
        address t = _getStorage().treasury;
        return t == address(0) ? owner() : t;
    }

    // ============ View Functions ============
    function feeCalculator() public view returns (address) {
        return _getStorage().feeCalculator;
    }


    function feeRecipient() external view returns (address) {
        return _getStorage().feeRecipient;
    }

    function feeBps() external view returns (uint256) {
        return _getStorage().feeBps;
    }

    function originationFeeBps() external view returns (uint256) {
        return _getStorage().originationFeeBps;
    }

    function lastTotalAssetsForFee() external view returns (uint256) {
        return _getStorage().lastTotalAssetsForFee;
    }

    /// @notice Returns the fee shares that would be minted if `_accrueFee` ran right now.
    function pendingFeeShares() external view returns (uint256 shares) {
        (, shares) = _accrueFeeView();
    }

    function totalLoanedAssets() public view returns (uint256) {
        return _getStorage().totalLoanedAssets;
    }

    function escrowedExcessTotal() external view returns (uint256) {
        return _getStorage().escrowedExcessTotal;
    }

    function escrowedExcessOf(address user) external view returns (uint256) {
        return _getStorage().escrowedExcess[user];
    }

    function getDebtBalance(address borrower) public view returns (uint256) {
        return _getStorage().debtBalance[borrower];
    }

    /**
     * @notice Returns the effective debt balance after accounting for vested-but-unsettled
     *         borrower rewards. Simulates _processGlobalVesting + per-user settlement in a
     *         view context so callers (e.g. isListingPurchasable) see accurate debt without
     *         requiring a state-changing settlement first.
     * @param borrower The address to query
     * @return The effective debt balance (stored debt minus pending borrower reward)
     */
    function getEffectiveDebtBalance(address borrower) public view returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 storedDebt = $.debtBalance[borrower];
        if (storedDebt == 0) return 0;

        uint256 userRate = $.userRewardRate[borrower];
        if (userRate == 0) return storedDebt;

        VestingSimulation memory sim = _simulateVesting();

        // Match _settleRewards: expired streams only get credit up to their epoch boundary
        uint256 accumulatorDelta;
        uint256 userFinish = $.userPeriodFinish[borrower];
        if (block.timestamp >= userFinish) {
            uint256 cappedAccumulator = $.epochEndBorrowerCreditPerRate[userFinish];
            if (cappedAccumulator == 0) {
                cappedAccumulator = _simulateBorrowerCreditPerRateAt(userFinish);
            }
            uint256 paid = $.userBorrowerCreditPerRatePaid[borrower];
            accumulatorDelta = cappedAccumulator > paid ? cappedAccumulator - paid : 0;
        } else {
            accumulatorDelta = sim.borrowerCreditPerRate - $.userBorrowerCreditPerRatePaid[borrower];
        }
        uint256 borrowerReward = (userRate * accumulatorDelta) / 1e18;

        if (borrowerReward > sim.globalBorrowerPending) {
            borrowerReward = sim.globalBorrowerPending;
        }

        if (borrowerReward >= storedDebt) {
            return 0;
        }
        return storedDebt - borrowerReward;
    }

    function paused() public view returns (bool) {
        return _getStorage().paused;
    }

    function isPauser(address account) public view returns (bool) {
        return _getStorage().pausers[account];
    }

    function getTotalDebtBalance() public view returns (uint256) {
        return _getStorage().totalDebtBalance;
    }

    function totalVestedRewardsApplied() external view returns (uint256) {
        return _getStorage().totalVestedRewardsApplied;
    }

    function getUnvestedLenderPremium() public view returns (uint256) {
        return _getUnvestedLenderPremium();
    }

    function getPendingRewards(address user) public view returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 rate = $.userRewardRate[user];
        if (rate == 0) return 0;
        if (block.timestamp >= $.userPeriodFinish[user]) return 0;
        return rate * ($.userPeriodFinish[user] - $.userLastSettledTime[user]);
    }

    function getVestedPendingRewards(address user) public view returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 rate = $.userRewardRate[user];
        if (rate == 0) return 0;
        uint256 currentTime = block.timestamp < $.userPeriodFinish[user] ? block.timestamp : $.userPeriodFinish[user];
        if (currentTime <= $.userLastSettledTime[user]) return 0;
        return rate * (currentTime - $.userLastSettledTime[user]);
    }

    function getGlobalBorrowerPending() public view returns (uint256) {
        return _getStorage().globalBorrowerPending;
    }

    function getActiveEpochRate() public view returns (uint256) {
        return _getStorage().activeEpochRate;
    }

    function getTotalUnsettledRewards() public view returns (uint256) {
        return _getStorage().totalUnsettledRewards;
    }

    function lenderPremiumUnlockedThisEpoch() public view returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 vestStart = $.vestingEpochStart;
        if (vestStart == 0) return 0;

        uint256 nowEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        // Past the vest epoch — premium fully realized into totalAssets, slot pending sweep
        if (nowEpoch > vestStart) return 0;

        uint256 vestPremium = $.vestingEpochPremium;
        if (vestPremium == 0) return 0;

        uint256 WEEK = ProtocolTimeLibrary.WEEK;
        uint256 elapsed = block.timestamp - vestStart;
        if (elapsed >= WEEK) return vestPremium;
        return (vestPremium * elapsed) / WEEK;
    }

    // ============ ERC4626 Override ============
    /// @notice NAV that reflects pending reward-stream vesting at block.timestamp.
    /// @dev    Simulates _processGlobalVesting without mutating storage so previews
    ///         match the values mint/burn would see after settlement. Pre-fix this
    ///         function read raw storage and could lag the true NAV between syncs;
    ///         that path is preserved as _totalAssetsRaw() for use by
    ///         getUtilizationPercent() to break the recursion
    ///         totalAssets -> _simulateVesting -> getCurrentVaultRatioBps -> getUtilizationPercent.
    function totalAssets() public view override returns (uint256) {
        return _totalAssetsFromSim(_simulateVesting());
    }

    /// @notice Raw NAV from current storage, without simulating pending vesting.
    /// @dev    Internal use only. Do NOT route external views through this -- ERC4626
    ///         consumers expect totalAssets() (the simulated value) so that preview
    ///         and execution agree. This helper exists exclusively to break the
    ///         recursion that would otherwise occur if getUtilizationPercent()
    ///         called the simulated totalAssets() (which itself needs the
    ///         utilization-derived fee ratio).
    function _totalAssetsRaw() internal view returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 totalReduction = $.totalVestedRewardsApplied + $.globalBorrowerPending;

        uint256 outstandingDebt;
        uint256 excessPendingOwedToBorrowers;
        if ($.totalLoanedAssets >= totalReduction) {
            outstandingDebt = $.totalLoanedAssets - totalReduction;
        } else {
            excessPendingOwedToBorrowers = totalReduction - $.totalLoanedAssets;
        }

        uint256 deductions = _getUnvestedLenderPremium()
            + $.totalUnsettledRewards
            + excessPendingOwedToBorrowers
            + $.escrowedExcessTotal;
        uint256 gross = IERC20(asset()).balanceOf(address(this)) + outstandingDebt;
        return gross > deductions ? gross - deductions : 0;
    }

    /// @notice Compose the simulated NAV from a VestingSimulation snapshot.
    function _totalAssetsFromSim(VestingSimulation memory sim) internal view returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 totalReduction = $.totalVestedRewardsApplied + sim.globalBorrowerPending;

        uint256 outstandingDebt;
        uint256 excessPendingOwedToBorrowers;
        if ($.totalLoanedAssets >= totalReduction) {
            outstandingDebt = $.totalLoanedAssets - totalReduction;
        } else {
            excessPendingOwedToBorrowers = totalReduction - $.totalLoanedAssets;
        }

        uint256 deductions = _getUnvestedLenderPremiumFromSim(sim)
            + sim.totalUnsettledRewards
            + excessPendingOwedToBorrowers
            + $.escrowedExcessTotal;
        uint256 gross = IERC20(asset()).balanceOf(address(this)) + outstandingDebt;
        return gross > deductions ? gross - deductions : 0;
    }

    // ============ Fee Calculator Functions ============
    function getCurrentVaultRatioBps() public view returns (uint256) {
        return getVaultRatioBps(getUtilizationPercent());
    }

    function getVaultRatioBps(uint256 utilizationBps) public view returns (uint256 rate) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        return IFeeCalculator($.feeCalculator).getVaultRatioBps(utilizationBps);
    }

    /// @notice Current borrow utilization in basis points (0-10000).
    /// @dev    Reads pre-simulation (raw) NAV by design. Never route this through
    ///         totalAssets() -- the simulated NAV calls getCurrentVaultRatioBps()
    ///         which calls back into this function, creating an infinite recursion.
    function getUtilizationPercent() public view returns (uint256) {
        uint256 total = _totalAssetsRaw();
        if (total == 0) return 0;
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 totalReduction = $.totalVestedRewardsApplied + $.globalBorrowerPending;
        uint256 effectiveLoaned = $.totalLoanedAssets > totalReduction ? $.totalLoanedAssets - totalReduction : 0;
        uint256 util = (effectiveLoaned * 10000) / total;
        return util > 10000 ? 10000 : util;
    }

    // ============ Lender Premium Vesting ============
    // Premium vests in the current epoch from epochStart(now).
    function _getUnvestedLenderPremium() internal view returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 vestStart = $.vestingEpochStart;
        if (vestStart == 0) return 0;

        uint256 nowEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        // Vest epoch has passed → fully realized, awaiting next-call sweep
        if (nowEpoch > vestStart) return 0;

        uint256 vestPremium = $.vestingEpochPremium;
        if (vestPremium == 0) return 0;

        uint256 WEEK = ProtocolTimeLibrary.WEEK;
        uint256 elapsed = block.timestamp - vestStart;
        if (elapsed >= WEEK) return 0;
        return vestPremium - (vestPremium * elapsed) / WEEK;
    }

    /// @notice View-side mirror of _getUnvestedLenderPremium that reads from a
    ///         VestingSimulation snapshot instead of storage.
    function _getUnvestedLenderPremiumFromSim(VestingSimulation memory sim) internal view returns (uint256) {
        uint256 vestStart = sim.vestingEpochStart;
        if (vestStart == 0) return 0;

        uint256 nowEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        if (nowEpoch > vestStart) return 0;

        uint256 vestPremium = sim.vestingEpochPremium;
        if (vestPremium == 0) return 0;

        uint256 WEEK = ProtocolTimeLibrary.WEEK;
        uint256 elapsed = block.timestamp - vestStart;
        if (elapsed >= WEEK) return 0;
        return vestPremium - (vestPremium * elapsed) / WEEK;
    }

    /// @notice Compute the state writes _processGlobalVesting would perform at
    ///         block.timestamp, without mutating storage. Single source of truth
    ///         for view-side vesting simulation; consumed by totalAssets and
    ///         getEffectiveDebtBalance.
    /// @dev    The fee-split ratio is sampled from raw (pre-simulation) state
    ///         via getCurrentVaultRatioBps() -> getUtilizationPercent() ->
    ///         _totalAssetsRaw(). Matches the state-changing path, which reads
    ///         the ratio before mutating vesting state.
    function _simulateVesting() internal view returns (VestingSimulation memory sim) {
        DynamicFeesVaultStorage storage $ = _getStorage();

        sim.vestingEpochPremium = $.vestingEpochPremium;
        sim.vestingEpochStart = $.vestingEpochStart;
        sim.totalUnsettledRewards = $.totalUnsettledRewards;
        sim.globalBorrowerPending = $.globalBorrowerPending;
        sim.borrowerCreditPerRate = $.borrowerCreditPerRate;

        uint256 currentRate = $.activeEpochRate;
        if (currentRate == 0) return sim;

        uint256 epochEnd = $.activeEpochEnd;
        uint256 lastUpdate = $.globalLastUpdateTime;
        uint256 currentTime = block.timestamp < epochEnd ? block.timestamp : epochEnd;
        if (currentTime <= lastUpdate) return sim;

        uint256 globalVested = currentRate * (currentTime - lastUpdate);
        bool epochEnded = block.timestamp >= epochEnd;
        if (epochEnded || globalVested > sim.totalUnsettledRewards) {
            globalVested = sim.totalUnsettledRewards;
        }

        uint256 ratio = getCurrentVaultRatioBps();
        uint256 lenderPremium = (globalVested * ratio) / 10000;
        uint256 borrowerCredit = globalVested - lenderPremium;

        if (lenderPremium > 0) {
            uint256 nowEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
            if (sim.vestingEpochStart > 0 && nowEpoch > sim.vestingEpochStart) {
                sim.vestingEpochPremium = 0;
                sim.vestingEpochStart = 0;
            }
            sim.vestingEpochPremium += lenderPremium;
            if (sim.vestingEpochStart < nowEpoch) {
                sim.vestingEpochStart = nowEpoch;
            }
        }

        if (borrowerCredit > 0) {
            sim.borrowerCreditPerRate += (borrowerCredit * 1e18) / currentRate;
        }

        sim.totalUnsettledRewards -= globalVested;
        sim.globalBorrowerPending += borrowerCredit;

        sim.globalVested = globalVested;
        sim.lenderPremium = lenderPremium;
        sim.borrowerCredit = borrowerCredit;
    }

    /// @notice Simulate borrowerCreditPerRate at a specified cutoff time (used by
    ///         getEffectiveDebtBalance when a user's stream expired but the
    ///         epoch-end snapshot has not yet been written by _processGlobalVesting).
    function _simulateBorrowerCreditPerRateAt(uint256 cutoff) internal view returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 acc = $.borrowerCreditPerRate;
        uint256 currentRate = $.activeEpochRate;
        uint256 lastUpdate = $.globalLastUpdateTime;
        if (currentRate == 0 || cutoff <= lastUpdate) return acc;

        uint256 vested = currentRate * (cutoff - lastUpdate);
        if (vested > $.totalUnsettledRewards) {
            vested = $.totalUnsettledRewards;
        }
        uint256 ratio = getCurrentVaultRatioBps();
        uint256 lenderPremium = (vested * ratio) / 10000;
        uint256 borrowerCredit = vested - lenderPremium;
        if (borrowerCredit > 0) {
            acc += (borrowerCredit * 1e18) / currentRate;
        }
        return acc;
    }

    // ============ Reward Streaming Functions ============

    /**
     * @notice Process global vesting of all active reward streams
     * @dev Called at the top of every state-changing function. Computes total vested
     *      from all streams, extracts lender premium, accumulates borrower credit.
     */
    function _processGlobalVesting() internal {
        DynamicFeesVaultStorage storage $ = _getStorage();

        uint256 currentRate = $.activeEpochRate;
        // Stream math runs only when there's an active stream; fee accrual at the end
        // ALWAYS runs so vestingEpochPremium decay during stream gaps still pays the
        // recipient.
        if (currentRate > 0) {
            uint256 currentTime = block.timestamp < $.activeEpochEnd ? block.timestamp : $.activeEpochEnd;
            if (currentTime > $.globalLastUpdateTime) {
                uint256 globalVested = currentRate * (currentTime - $.globalLastUpdateTime);
                $.globalLastUpdateTime = currentTime;

                bool epochEnded = block.timestamp >= $.activeEpochEnd;
                uint256 endingEpoch = $.activeEpochEnd;

                // Cap globalVested at totalUnsettledRewards to prevent underflow from rounding
                if (epochEnded || globalVested > $.totalUnsettledRewards) {
                    globalVested = $.totalUnsettledRewards;
                }

                // Compute fee split using current ratio
                uint256 ratio = getCurrentVaultRatioBps();
                uint256 lenderPremium = (globalVested * ratio) / 10000;
                uint256 borrowerCredit = globalVested - lenderPremium;

                // Lender premium vests in the CURRENT epoch from epochStart(now).
                //
                // ACCEPTED TRADE-OFF — RETROACTIVE SHARE-PRICE BOOST:
                // A lender who deposits at time T inside an epoch where premium has already
                // been extracted captures `(T - epochStart(now)) / WEEK` of the unvested
                // premium they did not fund.
                if (lenderPremium > 0) {
                    uint256 nowEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
                    if ($.vestingEpochStart > 0 && nowEpoch > $.vestingEpochStart) {
                        $.vestingEpochPremium = 0;
                        $.vestingEpochStart = 0;
                    }
                    $.vestingEpochPremium += lenderPremium;
                    if ($.vestingEpochStart < nowEpoch) {
                        $.vestingEpochStart = nowEpoch;
                    }
                }

                // Accumulate borrower credit per unit of stream rate (Synthetix-style)
                if (borrowerCredit > 0) {
                    $.borrowerCreditPerRate += (borrowerCredit * 1e18) / currentRate;
                }

                $.totalUnsettledRewards -= globalVested;
                $.globalBorrowerPending += borrowerCredit;

                // Freeze the accumulator at epoch boundary so expired streams can only
                // claim credit up to the epoch they participated in
                if (epochEnded) {
                    $.epochEndBorrowerCreditPerRate[endingEpoch] = $.borrowerCreditPerRate;
                    $.activeEpochRate = 0;
                    $.activeEpochEnd = 0;
                }
            }
        }

        // Accrue performance fee on realized interest delta. Runs even when no active
        // stream so unvested-premium decay during stream gaps is not missed.
        _accrueFee();
    }

    // ============ Performance Fee ============

    /**
     * @notice Mint fee shares to `feeRecipient` proportional to totalAssets growth since last accrual.
     * @dev Growth = increase in totalAssets() since `lastTotalAssetsForFee`. LP deposits and
     *      withdraws explicitly bump the snapshot in _deposit/_withdraw so they don't count as
     *      growth. Borrow/repay/depositRewards leave totalAssets() invariant by construction.
     */
    function _accrueFee() internal {
        DynamicFeesVaultStorage storage $ = _getStorage();
        (uint256 newTotalAssets, uint256 feeShares) = _accrueFeeView();
        if (feeShares == 0) return;

        address recipient = $.feeRecipient;
        uint256 feeBpsLocal = $.feeBps;
        uint256 growth = newTotalAssets > $.lastTotalAssetsForFee
            ? newTotalAssets - $.lastTotalAssetsForFee
            : 0;
        uint256 feeAssets = (growth * feeBpsLocal) / 10000;
        _mint(recipient, feeShares);
        emit FeeAccrued(recipient, feeAssets, feeShares);
        // Snapshot freezes when feeShares == 0 so sub-mintable totalAssets growth
        // accumulates across calls instead of leaking to LPs. Snapshot may briefly
        // exceed totalAssets() between premium extraction and recovery — intentional.
        $.lastTotalAssetsForFee = newTotalAssets;
    }

    /**
     * @notice View-only mirror of _accrueFee. Returns (newTotalAssets, feeSharesIfAccruedNow).
     */
    function _accrueFeeView() internal view returns (uint256 newTotalAssets, uint256 feeShares) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        newTotalAssets = totalAssets();
        uint256 last = $.lastTotalAssetsForFee;
        uint256 feeBpsLocal = $.feeBps;
        address recipient = $.feeRecipient;

        if (newTotalAssets <= last || feeBpsLocal == 0 || recipient == address(0)) {
            return (newTotalAssets, 0);
        }

        uint256 growth = newTotalAssets - last;
        uint256 feeAssets = (growth * feeBpsLocal) / 10000;
        if (feeAssets == 0) return (newTotalAssets, 0);

        uint256 virtualShares = 10 ** _decimalsOffset();
        uint256 newTotalAssetsWithoutFees = newTotalAssets - feeAssets;
        feeShares = (feeAssets * (totalSupply() + virtualShares)) / (newTotalAssetsWithoutFees + 1);
    }

    /**
     * @notice Settle vested rewards for a specific user, applying borrower credit to their debt
     * @param user The user whose rewards to settle
     */
    function _settleRewards(address user) internal {
        _processGlobalVesting();

        DynamicFeesVaultStorage storage $ = _getStorage();

        uint256 rate = $.userRewardRate[user];
        if (rate == 0) return;

        uint256 currentTime = block.timestamp < $.userPeriodFinish[user] ? block.timestamp : $.userPeriodFinish[user];
        if (currentTime <= $.userLastSettledTime[user]) return;

        $.userLastSettledTime[user] = currentTime;

        uint256 accumulatorDelta;

        if (block.timestamp >= $.userPeriodFinish[user]) {
            // Stream expired — only credit up to the epoch boundary, not beyond.
            // activeEpochRate was already zeroed by _processGlobalVesting so we
            // must not subtract from it here (it may belong to a newer epoch).
            uint256 cappedAccumulator = $.epochEndBorrowerCreditPerRate[$.userPeriodFinish[user]];
            uint256 paid = $.userBorrowerCreditPerRatePaid[user];
            accumulatorDelta = cappedAccumulator > paid ? cappedAccumulator - paid : 0;
            $.userBorrowerCreditPerRatePaid[user] = cappedAccumulator;
            $.userRewardRate[user] = 0;
            $.userPeriodFinish[user] = 0;
        } else {
            accumulatorDelta = $.borrowerCreditPerRate - $.userBorrowerCreditPerRatePaid[user];
            $.userBorrowerCreditPerRatePaid[user] = $.borrowerCreditPerRate;
        }

        uint256 borrowerReward = (rate * accumulatorDelta) / 1e18;
        if (borrowerReward > $.globalBorrowerPending) {
            borrowerReward = $.globalBorrowerPending;
        }

        // Apply to user's debt
        uint256 oldDebtBalance = $.debtBalance[user];
        if (borrowerReward > 0 && oldDebtBalance > 0) {
            if (borrowerReward > oldDebtBalance) {
                uint256 excess = borrowerReward - oldDebtBalance;
                $.debtBalance[user] = 0;
                $.totalDebtBalance -= oldDebtBalance;
                $.totalVestedRewardsApplied += oldDebtBalance;
                $.globalBorrowerPending -= borrowerReward;
                _transferOrEscrow($, user, excess);
            } else {
                $.debtBalance[user] -= borrowerReward;
                $.totalDebtBalance -= borrowerReward;
                $.totalVestedRewardsApplied += borrowerReward;
                $.globalBorrowerPending -= borrowerReward;
            }

            emit DebtBalanceUpdated(user, oldDebtBalance, $.debtBalance[user], borrowerReward);
        } else if (borrowerReward > 0 && oldDebtBalance == 0) {
            // No debt — send full borrower reward as excess
            $.globalBorrowerPending -= borrowerReward;
            _transferOrEscrow($, user, borrowerReward);
        }
    }

    /**
     * @notice Attempt transfer, escrow on failure (e.g. USDC blacklist)
     */
    function _transferOrEscrow(DynamicFeesVaultStorage storage $, address user, uint256 amount) internal {
        if (amount == 0) return;
        if (IERC20(asset()).trySafeTransfer(user, amount)) {
            emit ExcessRewardsPaid(user, amount);
        } else {
            $.escrowedExcess[user] += amount;
            $.escrowedExcessTotal += amount;
            emit ExcessRewardsEscrowed(user, amount);
        }
    }

    /**
     * @notice Claim escrowed excess rewards that failed to transfer
     */
    function claimEscrow() external nonReentrant {
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 amount = $.escrowedExcess[msg.sender];
        if (amount == 0) revert ZeroAmount();
        $.escrowedExcess[msg.sender] = 0;
        $.escrowedExcessTotal -= amount;
        IERC20(asset()).safeTransfer(msg.sender, amount);
        emit EscrowClaimed(msg.sender, amount);
    }

    /**
     * @notice Public wrapper to settle rewards for any user
     * @param user The user whose rewards to settle
     */
    function settleRewards(address user) external {
        _settleRewards(user);
    }

    // ============ Core Vault Functions ============
    function repay(uint256 amount) external whenNotPaused {
        _settleRewards(msg.sender);

        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 userDebtBalance = $.debtBalance[msg.sender];
        uint256 amountToRepay = userDebtBalance < amount ? userDebtBalance : amount;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amountToRepay);
        $.totalLoanedAssets -= amountToRepay;
        $.debtBalance[msg.sender] -= amountToRepay;
        $.totalDebtBalance -= amountToRepay;
        emit Repaid(msg.sender, amountToRepay, $.debtBalance[msg.sender]);
    }

    function depositRewards(uint256 amount) external whenNotPaused onlyPortfolio {
        if (amount == 0) revert ZeroAmount();
        require(_getStorage().debtBalance[msg.sender] > 0, "No debt to repay");

        DynamicFeesVaultStorage storage $ = _getStorage();

        // Settle BEFORE the transfer so _accrueFee sees pre-deposit totalAssets and
        // doesn't treat the inflow as interest. Mirrors repay / borrow / payFromPortfolio.
        _settleRewards(msg.sender);

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        // Compute remaining unsettled from existing stream
        uint256 remaining = 0;
        if ($.userRewardRate[msg.sender] > 0 && $.userPeriodFinish[msg.sender] > block.timestamp) {
            remaining = $.userRewardRate[msg.sender] * ($.userPeriodFinish[msg.sender] - block.timestamp);
            $.activeEpochRate -= $.userRewardRate[msg.sender]; // remove old rate from global
        }

        // Create new stream combining remaining + new amount
        uint256 total = remaining + amount;
        uint256 periodFinish = ProtocolTimeLibrary.epochNext(block.timestamp);
        uint256 duration = periodFinish - block.timestamp;
        uint256 newRate = total / duration;
        require(newRate > 0, "Amount too small");

        $.userRewardRate[msg.sender] = newRate;
        $.userPeriodFinish[msg.sender] = periodFinish;
        $.userLastSettledTime[msg.sender] = block.timestamp;

        $.activeEpochRate += newRate;
        if ($.activeEpochEnd != periodFinish) {
            $.activeEpochEnd = periodFinish;
        }
        if ($.globalLastUpdateTime < block.timestamp) {
            $.globalLastUpdateTime = block.timestamp;
        }

        $.totalUnsettledRewards += amount;

        // Snapshot accumulator for the new stream rate
        $.userBorrowerCreditPerRatePaid[msg.sender] = $.borrowerCreditPerRate;

        emit RewardsMinted(msg.sender, amount);
    }

    /// @notice Permissionless lender-side incentive top-up. 100% to lender premium,
    /// vests linearly over the current epoch. No matching borrower-credit stream.
    function incentivize(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        DynamicFeesVaultStorage storage $ = _getStorage();

        _processGlobalVesting();

        // Transfer before storage write so totalAssets() is non-decreasing mid-call.
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        uint256 nowEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        if ($.vestingEpochStart > 0 && nowEpoch > $.vestingEpochStart) {
            $.vestingEpochPremium = 0;
            $.vestingEpochStart = 0;
        }
        $.vestingEpochPremium += amount;
        if ($.vestingEpochStart < nowEpoch) {
            $.vestingEpochStart = nowEpoch;
        }

        emit Incentivized(msg.sender, amount, nowEpoch);
    }

    // ============ ILendingPool Implementation ============
    function borrowFromPortfolio(uint256 amount) external onlyPortfolio whenNotPaused returns (uint256 originationFee) {
        _settleRewards(msg.sender);

        DynamicFeesVaultStorage storage $ = _getStorage();

        originationFee = (amount * $.originationFeeBps) / 10000;
        uint256 amountAfterFee = amount - originationFee;

        $.debtBalance[msg.sender] += amount;
        $.totalDebtBalance += amount;
        $.totalLoanedAssets += amount;

        IERC20(asset()).safeTransfer(msg.sender, amountAfterFee);
        if (originationFee > 0) {
            IERC20(asset()).safeTransfer(getTreasury(), originationFee);
        }

        emit Borrowed(msg.sender, amount);
    }

    function payFromPortfolio(uint256 totalPayment, uint256 feesToPay) external whenNotPaused returns (uint256 actualPaid) {
        _settleRewards(msg.sender);

        DynamicFeesVaultStorage storage $ = _getStorage();

        // Cap fees at total payment to prevent underflow
        if (feesToPay > totalPayment) {
            feesToPay = totalPayment;
        }

        if (feesToPay > 0) {
            IERC20(asset()).safeTransferFrom(msg.sender, getTreasury(), feesToPay);
        }

        uint256 amountToRepay;
        uint256 balanceToPay = totalPayment - feesToPay;
        if (balanceToPay > 0) {
            uint256 userDebtBalance = $.debtBalance[msg.sender];
            amountToRepay = userDebtBalance < balanceToPay ? userDebtBalance : balanceToPay;

            IERC20(asset()).safeTransferFrom(msg.sender, address(this), amountToRepay);
            $.totalLoanedAssets -= amountToRepay;
            $.debtBalance[msg.sender] -= amountToRepay;
            $.totalDebtBalance -= amountToRepay;
            emit Repaid(msg.sender, amountToRepay, $.debtBalance[msg.sender]);
        }

        return feesToPay + amountToRepay;
    }

    function lendingAsset() external view returns (address) {
        return asset();
    }

    function _asset() external view returns (address) {
        return asset();
    }

    function lendingVault() external view returns (address) {
        return address(this);
    }

    function activeAssets() external view returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 totalReduction = $.totalVestedRewardsApplied + $.globalBorrowerPending;
        return $.totalLoanedAssets > totalReduction
            ? $.totalLoanedAssets - totalReduction
            : 0;
    }

    function sync() public {
        _processGlobalVesting();
        DynamicFeesVaultStorage storage $ = _getStorage();
        // Inline stale-vesting-bucket sweep (was _rollLenderPremium): handles the
        // no-fresh-premium case where _processGlobalVesting did not run the sweep.
        uint256 nowEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        if ($.vestingEpochStart > 0 && nowEpoch > $.vestingEpochStart) {
            $.vestingEpochPremium = 0;
            $.vestingEpochStart = 0;
        }
        emit Synced(
            ProtocolTimeLibrary.epochStart(block.timestamp),
            $.totalLoanedAssets,
            $.totalVestedRewardsApplied
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
    function maxDeposit(address) public view override returns (uint256) {
        if (_getStorage().paused) return 0;
        return type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        if (_getStorage().paused) return 0;
        return type(uint256).max;
    }

    /// @dev All four preview functions fold in `pendingFeeShares` so quotes match what users
    ///      actually receive after the next state-changing call accrues the fee.
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        (uint256 newTotalAssets, uint256 pending) = _accrueFeeView();
        uint256 newTotalSupply = totalSupply() + pending;
        return Math.mulDiv(assets, newTotalSupply + 10 ** _decimalsOffset(), newTotalAssets + 1, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        (uint256 newTotalAssets, uint256 pending) = _accrueFeeView();
        uint256 newTotalSupply = totalSupply() + pending;
        return Math.mulDiv(shares, newTotalAssets + 1, newTotalSupply + 10 ** _decimalsOffset(), Math.Rounding.Ceil);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        (uint256 newTotalAssets, uint256 pending) = _accrueFeeView();
        uint256 newTotalSupply = totalSupply() + pending;
        return Math.mulDiv(assets, newTotalSupply + 10 ** _decimalsOffset(), newTotalAssets + 1, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        (uint256 newTotalAssets, uint256 pending) = _accrueFeeView();
        uint256 newTotalSupply = totalSupply() + pending;
        return Math.mulDiv(shares, newTotalAssets + 1, newTotalSupply + 10 ** _decimalsOffset(), Math.Rounding.Floor);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        if ($.paused) return 0;
        if ($.lastDepositBlock[owner] >= block.number) return 0;
        // Mirror previewWithdraw's accrual so withdraw(maxWithdraw(owner)) cannot revert in _burn.
        (uint256 newTotalAssets, uint256 pending) = _accrueFeeView();
        uint256 newTotalSupply = totalSupply() + pending;
        uint256 assets = Math.mulDiv(
            balanceOf(owner),
            newTotalAssets + 1,
            newTotalSupply + 10 ** _decimalsOffset(),
            Math.Rounding.Floor
        );
        uint256 liquid = IERC20(asset()).balanceOf(address(this));
        return assets < liquid ? assets : liquid;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        if ($.paused) return 0;
        if ($.lastDepositBlock[owner] >= block.number) return 0;
        (uint256 newTotalAssets, uint256 pending) = _accrueFeeView();
        uint256 newTotalSupply = totalSupply() + pending;
        uint256 shares = balanceOf(owner);
        uint256 liquid = IERC20(asset()).balanceOf(address(this));
        uint256 maxShares = Math.mulDiv(
            liquid,
            newTotalSupply + 10 ** _decimalsOffset(),
            newTotalAssets + 1,
            Math.Rounding.Floor
        );
        return shares < maxShares ? shares : maxShares;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        _processGlobalVesting();

        DynamicFeesVaultStorage storage $ = _getStorage();
        if ($.paused) revert ContractPaused();

        if (caller == receiver) {
            $.lastDepositBlock[receiver] = block.number;
        }

        super._deposit(caller, receiver, assets, shares);

        // totalAssets() rose by `assets`; not interest, so bump the snapshot.
        $.lastTotalAssetsForFee += assets;
    }

    function _withdraw(
        address caller,
        address receiver,
        address _owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        _processGlobalVesting();

        DynamicFeesVaultStorage storage $ = _getStorage();
        if ($.paused) revert ContractPaused();

        require($.lastDepositBlock[_owner] < block.number, "Cannot withdraw in same block as deposit");

        super._withdraw(caller, receiver, _owner, assets, shares);

        // totalAssets() fell by `assets`; mirror in the snapshot with zero-floor guard.
        uint256 last = $.lastTotalAssetsForFee;
        $.lastTotalAssetsForFee = last > assets ? last - assets : 0;
    }

    // ============ ERC4626 Inflation Attack Prevention ============
    function _decimalsOffset() internal view override returns (uint8) {
        return _getStorage().sharesDecimalsOffset;
    }

    function getPortfolioFactory() external view returns (address) {
        return _getStorage().portfolioFactory;
    }

    // ============ Access Control ============
    modifier onlyPortfolio() {
        DynamicFeesVaultStorage storage $ = _getStorage();
        require(IPortfolioFactory($.portfolioFactory).isPortfolio(msg.sender), "Only portfolio can call this function");
        _;
    }
}
