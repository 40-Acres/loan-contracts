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
    event DebtTransferred(address indexed from, address indexed to, uint256 amount);

    // ============ Errors ============
    error ContractPaused();
    error NotPauser();
    error AlreadyPauser();
    error NotAPauser();
    error ZeroAmount();
    error ZeroAddress();

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
        uint256 currentEpochPremium;     // Premium deposited in current epoch (not vesting yet)
        uint256 currentEpochStart;       // Epoch start time for currentEpochPremium
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
        uint256 lastGlobalRatio;         // cached ratio from last _processGlobalVesting for per-user consistency
        uint8 sharesDecimalsOffset;      // asset decimals used as virtual share offset for inflation attack prevention
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
        $.sharesDecimalsOffset = ERC20(_asset).decimals();

        // Deploy the default fee calculator
        FeeCalculator feeCalc = new FeeCalculator();
        $.feeCalculator = address(feeCalc);
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
        uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);
        uint256 WEEK = ProtocolTimeLibrary.WEEK;

        uint256 vestPremium = $.vestingEpochPremium;
        uint256 vestStart = $.vestingEpochStart;
        uint256 currentPremium = $.currentEpochPremium;
        uint256 currentStart = $.currentEpochStart;

        // Simulate roll
        if (vestStart > 0 && epochStart > vestStart) {
            vestPremium = 0; vestStart = 0;
        }
        if (currentStart > 0 && epochStart > currentStart) {
            uint256 vestEpochStart = currentStart + WEEK;
            if (epochStart <= vestEpochStart) {
                vestPremium += currentPremium;
                vestStart = vestEpochStart;
            }
        }

        if (vestPremium == 0 || vestStart == 0) return 0;
        uint256 elapsed = block.timestamp - vestStart;
        if (elapsed >= WEEK) return vestPremium;
        return (vestPremium * elapsed) / WEEK;
    }

    // ============ ERC4626 Override ============
    function totalAssets() public view override returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 totalReduction = $.totalVestedRewardsApplied + $.globalBorrowerPending;
        uint256 outstandingDebt = $.totalLoanedAssets > totalReduction
            ? $.totalLoanedAssets - totalReduction : 0;
        uint256 unvested = _getUnvestedLenderPremium();
        uint256 total = IERC20(asset()).balanceOf(address(this)) + outstandingDebt;
        return total > (unvested + $.totalUnsettledRewards)
            ? total - unvested - $.totalUnsettledRewards : 0;
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
        uint256 util = ($.totalLoanedAssets * 10000) / total;
        return util > 10000 ? 10000 : util;
    }

    // ============ Lender Premium Vesting ============
    function _rollLenderPremium() internal {
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);

        // Step 1: If vesting epoch is in the past, its premium is fully vested — clear it
        if ($.vestingEpochStart > 0 && epochStart > $.vestingEpochStart) {
            $.vestingEpochPremium = 0;
            $.vestingEpochStart = 0;
        }

        // Step 2: If current epoch premium is from a past epoch, promote to vesting
        if ($.currentEpochStart > 0 && epochStart > $.currentEpochStart) {
            uint256 vestEpochStart = $.currentEpochStart + ProtocolTimeLibrary.WEEK;
            if (epochStart <= vestEpochStart) {
                // We're in the immediate next epoch — move to vesting
                $.vestingEpochPremium += $.currentEpochPremium;
                $.vestingEpochStart = vestEpochStart;
            }
            // else: gap > 1 epoch — premium already fully vested, nothing to do
            $.currentEpochPremium = 0;
            $.currentEpochStart = epochStart;
        }
    }

    function _getUnvestedLenderPremium() internal view returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);
        uint256 WEEK = ProtocolTimeLibrary.WEEK;
        uint256 unvested = 0;

        // Simulate the roll to get current-state values
        uint256 currentPremium = $.currentEpochPremium;
        uint256 currentStart = $.currentEpochStart;
        uint256 vestPremium = $.vestingEpochPremium;
        uint256 vestStart = $.vestingEpochStart;

        // Clear vesting if its epoch has passed
        if (vestStart > 0 && epochStart > vestStart) {
            vestPremium = 0;
            vestStart = 0;
        }

        // Promote current to vesting if epoch advanced
        if (currentStart > 0 && epochStart > currentStart) {
            uint256 vestEpochStart = currentStart + WEEK;
            if (epochStart <= vestEpochStart) {
                vestPremium += currentPremium;
                vestStart = vestEpochStart;
            }
            currentPremium = 0;
        }

        // Current epoch premium is completely unvested
        unvested += currentPremium;

        // Vesting premium: linearly releasing over its epoch
        if (vestPremium > 0 && vestStart > 0) {
            uint256 elapsed = block.timestamp - vestStart;
            if (elapsed < WEEK) {
                unvested += vestPremium - (vestPremium * elapsed) / WEEK;
            }
            // else: fully vested
        }

        return unvested;
    }

    // ============ Reward Streaming Functions ============

    /**
     * @notice Process global vesting of all active reward streams
     * @dev Called at the top of every state-changing function. Computes total vested
     *      from all streams, extracts lender premium, accumulates borrower credit.
     */
    function _processGlobalVesting() internal {
        DynamicFeesVaultStorage storage $ = _getStorage();

        if ($.activeEpochRate == 0) return;

        uint256 currentTime = block.timestamp < $.activeEpochEnd ? block.timestamp : $.activeEpochEnd;
        if (currentTime <= $.globalLastUpdateTime) return;

        uint256 globalVested = $.activeEpochRate * (currentTime - $.globalLastUpdateTime);
        $.globalLastUpdateTime = currentTime;

        // If past epoch end, clear the rate
        if (block.timestamp >= $.activeEpochEnd) {
            $.activeEpochRate = 0;
            $.activeEpochEnd = 0;
        }

        // Cap globalVested at totalUnsettledRewards to prevent underflow from rounding
        if (globalVested > $.totalUnsettledRewards) {
            globalVested = $.totalUnsettledRewards;
        }

        // Compute fee split using current ratio and cache for per-user consistency
        uint256 ratio = getCurrentVaultRatioBps();
        $.lastGlobalRatio = ratio;
        uint256 lenderPremium = (globalVested * ratio) / 10000;
        uint256 borrowerCredit = globalVested - lenderPremium;

        // Track lender premium — deposit into current epoch, vests next epoch
        if (lenderPremium > 0) {
            _rollLenderPremium();
            $.currentEpochPremium += lenderPremium;
            if ($.currentEpochStart == 0) {
                $.currentEpochStart = ProtocolTimeLibrary.epochStart(block.timestamp);
            }
        }

        $.totalUnsettledRewards -= globalVested;
        $.globalBorrowerPending += borrowerCredit;
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

        uint256 userVested = rate * (currentTime - $.userLastSettledTime[user]);
        $.userLastSettledTime[user] = currentTime;

        // If past period finish, clear user stream and defensively clean up global rate
        if (block.timestamp >= $.userPeriodFinish[user]) {
            if ($.activeEpochRate >= rate) {
                $.activeEpochRate -= rate;
            }
            $.userRewardRate[user] = 0;
            $.userPeriodFinish[user] = 0;
        }

        // Compute borrower reward using cached global ratio for consistency
        uint256 borrowerReward = userVested - (userVested * $.lastGlobalRatio) / 10000;
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
                IERC20(asset()).safeTransfer(user, excess);
                emit ExcessRewardsPaid(user, excess);
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
            IERC20(asset()).safeTransfer(user, borrowerReward);
            emit ExcessRewardsPaid(user, borrowerReward);
        }
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
    }

    function repayWithRewards(uint256 amount) external whenNotPaused onlyPortfolio {
        if (amount == 0) revert ZeroAmount();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        DynamicFeesVaultStorage storage $ = _getStorage();

        // Settle any existing vested rewards for this user
        _settleRewards(msg.sender);

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

        uint256 actualVesting = newRate * duration;
        $.totalUnsettledRewards = $.totalUnsettledRewards - remaining + actualVesting;

        emit RewardsMinted(msg.sender, amount);
    }

    // ============ ILendingPool Implementation ============
    function borrowFromPortfolio(uint256 amount) external onlyPortfolio whenNotPaused returns (uint256 originationFee) {
        _settleRewards(msg.sender);

        DynamicFeesVaultStorage storage $ = _getStorage();

        uint256 total = totalAssets();
        uint256 postBorrowLoaned = $.totalLoanedAssets + amount;
        uint256 postBorrowUtilization = total > 0 ? (postBorrowLoaned * 10000) / total : 0;
        require(postBorrowUtilization < 8000, "Borrow would exceed 80% utilization");

        IERC20(asset()).safeTransfer(msg.sender, amount);
        $.debtBalance[msg.sender] += amount;
        $.totalDebtBalance += amount;
        $.totalLoanedAssets += amount;

        return 0;
    }

    function payFromPortfolio(uint256 totalPayment, uint256 feesToPay) external whenNotPaused returns (uint256 actualPaid) {
        _settleRewards(msg.sender);

        DynamicFeesVaultStorage storage $ = _getStorage();

        // Cap fees at total payment to prevent underflow
        if (feesToPay > totalPayment) {
            feesToPay = totalPayment;
        }

        if (feesToPay > 0) {
            IERC20(asset()).safeTransferFrom(msg.sender, owner(), feesToPay);
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
        return _getStorage().totalLoanedAssets;
    }

    function transferDebt(address from, address to, uint256 amount) external onlyPortfolio {
        _settleRewards(from);
        _settleRewards(to);

        DynamicFeesVaultStorage storage $ = _getStorage();

        uint256 fromBalance = $.debtBalance[from];
        uint256 transferAmount = amount > fromBalance ? fromBalance : amount;

        $.debtBalance[from] -= transferAmount;
        $.debtBalance[to] += transferAmount;

        emit DebtTransferred(from, to, transferAmount);
    }

    function sync() public {
        _processGlobalVesting();
        DynamicFeesVaultStorage storage $ = _getStorage();
        _rollLenderPremium();
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

    function maxWithdraw(address owner) public view override returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        if ($.paused) return 0;
        if ($.lastDepositBlock[owner] >= block.number) return 0;
        uint256 assets = convertToAssets(balanceOf(owner));
        uint256 liquid = IERC20(asset()).balanceOf(address(this));
        return assets < liquid ? assets : liquid;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getStorage();
        if ($.paused) return 0;
        if ($.lastDepositBlock[owner] >= block.number) return 0;
        uint256 shares = balanceOf(owner);
        uint256 liquid = IERC20(asset()).balanceOf(address(this));
        uint256 maxShares = convertToShares(liquid);
        return shares < maxShares ? shares : maxShares;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        _processGlobalVesting();

        DynamicFeesVaultStorage storage $ = _getStorage();
        if ($.paused) revert ContractPaused();

        $.lastDepositBlock[receiver] = block.number;

        super._deposit(caller, receiver, assets, shares);
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
    }

    // ============ ERC20 Override ============
    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value);
        // Propagate flash loan protection to share transfer recipients
        if (from != address(0) && to != address(0)) {
            DynamicFeesVaultStorage storage $ = _getStorage();
            if ($.lastDepositBlock[from] >= block.number) {
                $.lastDepositBlock[to] = block.number;
            }
        }
    }

    // ============ ERC4626 Inflation Attack Prevention ============
    function _decimalsOffset() internal view override returns (uint8) {
        return _getStorage().sharesDecimalsOffset;
    }

    // ============ Access Control ============
    modifier onlyPortfolio() {
        DynamicFeesVaultStorage storage $ = _getStorage();
        require(IPortfolioFactory($.portfolioFactory).isPortfolio(msg.sender), "Only portfolio can call this function");
        _;
    }
}
