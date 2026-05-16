// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ILendingPool} from "../../../interfaces/ILendingPool.sol";
import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {ProtocolTimeLibrary} from "../../../libraries/ProtocolTimeLibrary.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
/**
 * @title LendingVault
 * @dev ERC4626 vault that lends directly to portfolio accounts (no Loan intermediary).
 *
 * Lenders deposit USDC → receive vault shares.
 * Borrowers (portfolio accounts) call borrowFromPortfolio/payFromPortfolio via ERC4626CollateralManager.
 * Per-borrower debt tracked in storage. Vault is the source of truth for debt.
 *
 * totalAssets = USDC balance + total loaned out
 * share price appreciates as origination fees are collected.
 */
contract LendingVault is Initializable, ERC4626Upgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, ILendingPool {
    using SafeERC20 for IERC20;

    /// @notice Maximum origination fee in basis points (10%)
    uint256 public constant MAX_FEE_BPS = 1000;

    /// @custom:storage-location erc7201:storage.LendingVault
    struct LendingVaultStorage {
        PortfolioFactory portfolioFactory;
        address owner;
        uint256 totalLoanedAssets;
        mapping(address => uint256) debtBalance;
        uint256 maxUtilizationBps; // e.g. 8000 = 80%
        uint256 originationFeeBps; // e.g. 50 = 0.5%
        bool paused;
        // Epoch-based reward vesting: fees trickle into totalAssets over the epoch
        uint256 currentEpochRewards; // accumulated fees this epoch
        uint256 currentEpochStart;   // start timestamp of current epoch
        mapping(address => uint256) lastDepositBlock; // flash-deposit protection
        uint8 sharesDecimalsOffset; // asset decimals cached at init for inflation-attack-resistant offset
    }

    bytes32 private constant STORAGE_POSITION = keccak256("storage.LendingVault");

    event Borrowed(address indexed borrower, uint256 amount, uint256 originationFee);
    event Repaid(address indexed borrower, uint256 amount);
    event RewardsDeposited(address indexed from, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error NotOwner();
    error NotPortfolio();
    error ExceedsUtilization();
    error VaultPaused();
    error ZeroAmount();
    error FeeBpsTooHigh();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address asset_,
        address portfolioFactory_,
        address owner_,
        string memory name_,
        string memory symbol_,
        uint256 maxUtilizationBps_,
        uint256 originationFeeBps_
    ) public initializer {
        if (originationFeeBps_ > MAX_FEE_BPS) revert FeeBpsTooHigh();

        __ERC4626_init(ERC20(asset_));
        __ERC20_init(name_, symbol_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        LendingVaultStorage storage $ = _getStorage();
        $.portfolioFactory = PortfolioFactory(portfolioFactory_);
        $.owner = owner_;
        $.maxUtilizationBps = maxUtilizationBps_;
        $.originationFeeBps = originationFeeBps_;
        $.sharesDecimalsOffset = IERC20Metadata(asset_).decimals();
    }

    // ============ ILendingPool ============

    function borrowFromPortfolio(uint256 amount) external nonReentrant onlyPortfolio whenNotPaused returns (uint256 originationFee) {
        if (amount == 0) revert ZeroAmount();

        LendingVaultStorage storage $ = _getStorage();

        // Calculate origination fee
        originationFee = (amount * $.originationFeeBps) / 10000;
        uint256 amountAfterFee = amount - originationFee;

        // Check utilization cap. Zero totalAssets is treated as fully utilized:
        // any borrow against a zero-asset vault is by definition over the cap.
        uint256 total = totalAssets();
        if (total == 0) revert ExceedsUtilization();
        uint256 postBorrowLoaned = $.totalLoanedAssets + amount;
        if (postBorrowLoaned * 10000 >= $.maxUtilizationBps * total) revert ExceedsUtilization();

        // Track debt (full amount — borrower owes amount, vault disbursed amount)
        $.debtBalance[msg.sender] += amount;
        $.totalLoanedAssets += amount;

        // Transfer loan to borrower, fee to owner
        IERC20(asset()).safeTransfer(msg.sender, amountAfterFee);
        if (originationFee > 0) {
            IERC20(asset()).safeTransfer($.owner, originationFee);
        }

        emit Borrowed(msg.sender, amount, originationFee);
    }

    function payFromPortfolio(uint256 totalPayment, uint256 feesToPay) external nonReentrant onlyPortfolio returns (uint256 actualPaid) {
        LendingVaultStorage storage $ = _getStorage();

        // Cap fees at total payment
        if (feesToPay > totalPayment) {
            feesToPay = totalPayment;
        }

        // Transfer protocol fees to owner
        if (feesToPay > 0) {
            IERC20(asset()).safeTransferFrom(msg.sender, $.owner, feesToPay);
        }

        // Repay debt
        uint256 balanceToPay = totalPayment - feesToPay;
        if (balanceToPay > 0) {
            uint256 userDebt = $.debtBalance[msg.sender];
            uint256 amountToRepay = userDebt < balanceToPay ? userDebt : balanceToPay;

            if (amountToRepay > 0) {
                IERC20(asset()).safeTransferFrom(msg.sender, address(this), amountToRepay);
                $.debtBalance[msg.sender] -= amountToRepay;
                $.totalLoanedAssets -= amountToRepay;
            }

            actualPaid = feesToPay + amountToRepay;
        } else {
            actualPaid = feesToPay;
        }

        emit Repaid(msg.sender, actualPaid);
    }

    function lendingAsset() external view returns (address) {
        return asset();
    }

    function lendingVault() external view returns (address) {
        return address(this);
    }

    /// @notice ILoan-compatible: returns self so PortfolioFactoryConfig.getVault() works
    function _vault() external view returns (address) {
        return address(this);
    }

    /// @notice ILoan-compatible: returns the underlying asset
    function _asset() external view returns (address) {
        return asset();
    }

    function activeAssets() external view returns (uint256) {
        return _getStorage().totalLoanedAssets;
    }

    // ============ Debt Balance Reader (for ERC4626CollateralManager) ============

    function getDebtBalance(address borrower) public view returns (uint256) {
        return _getStorage().debtBalance[borrower];
    }

    function getEffectiveDebtBalance(address borrower) external view returns (uint256) {
        return getDebtBalance(borrower);
    }

    // ============ ERC4626 Overrides ============

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + _getStorage().totalLoanedAssets - epochRewardsLocked();
    }

    // Override ERC4626 view functions to cap at liquid asset balance
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (_getStorage().lastDepositBlock[owner] >= block.number) return 0;
        uint256 liquidAssets = IERC20(asset()).balanceOf(address(this));
        uint256 maxAssets = super.maxWithdraw(owner);
        return liquidAssets < maxAssets ? liquidAssets : maxAssets;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (_getStorage().lastDepositBlock[owner] >= block.number) return 0;
        uint256 liquidAssets = IERC20(asset()).balanceOf(address(this));
        uint256 maxShares = super.maxRedeem(owner);
        uint256 maxAssets = convertToAssets(maxShares);
        if (maxAssets > liquidAssets) {
            return convertToShares(liquidAssets);
        }
        return maxShares;
    }

    function _decimalsOffset() internal view override returns (uint8) {
        return _getStorage().sharesDecimalsOffset;
    }

    /// @dev Track the block of every share mint for flash-deposit protection.
    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value);
        if (from == address(0) && to != address(0)) {
            _getStorage().lastDepositBlock[to] = block.number;
        }
    }

    function _withdraw(
        address caller,
        address receiver,
        address _owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        require(_getStorage().lastDepositBlock[_owner] < block.number, "Cannot withdraw in same block as deposit");
        super._withdraw(caller, receiver, _owner, assets, shares);
    }



    // ============ Epoch Reward Vesting ============

    /**
     * @notice Returns the portion of epoch rewards still locked (not yet vested).
     * @dev Rewards vest linearly over the epoch. At epoch start, 100% locked.
     *      At epoch end, 0% locked. Previous epoch rewards are fully vested.
     */
    function epochRewardsLocked() public view returns (uint256) {
        LendingVaultStorage storage $ = _getStorage();
        uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);

        // If rewards are from a previous epoch, they're fully vested
        if ($.currentEpochStart < epochStart) {
            return 0;
        }

        uint256 epochTimeRemaining = ProtocolTimeLibrary.epochNext(block.timestamp) - block.timestamp;
        return (epochTimeRemaining * $.currentEpochRewards) / ProtocolTimeLibrary.WEEK;
    }

    /**
     * @notice Get the current epoch's total rewards (for external queries)
     */
    function lastEpochReward() external view returns (uint256) {
        return _getStorage().currentEpochRewards;
    }

    /**
     * @notice Deposit rewards into the vault (e.g. from gauge claim proceeds).
     * @dev Rewards vest linearly over the current epoch to prevent share price manipulation.
     *      Can be called by portfolio accounts or authorized callers.
     * @param amount Amount of reward tokens (same as vault asset) to deposit
     */
    function depositRewards(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);

        LendingVaultStorage storage $ = _getStorage();
        _accumulateEpochReward($, amount);

        emit RewardsDeposited(msg.sender, amount);
    }

    function _accumulateEpochReward(LendingVaultStorage storage $, uint256 amount) internal {
        uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);

        if ($.currentEpochStart < epochStart) {
            // New epoch — previous rewards fully vested, start fresh
            $.currentEpochRewards = amount;
            $.currentEpochStart = epochStart;
        } else {
            // Same epoch — add to existing rewards
            $.currentEpochRewards += amount;
        }
    }

    // ============ Admin ============

    function setMaxUtilization(uint256 maxUtilizationBps_) external onlyOwner {
        _getStorage().maxUtilizationBps = maxUtilizationBps_;
    }

    function setOriginationFee(uint256 originationFeeBps_) external onlyOwner {
        if (originationFeeBps_ > MAX_FEE_BPS) revert FeeBpsTooHigh();
        _getStorage().originationFeeBps = originationFeeBps_;
    }

    function pause() external onlyOwner {
        _getStorage().paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        _getStorage().paused = false;
        emit Unpaused(msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        LendingVaultStorage storage $ = _getStorage();
        address prev = $.owner;
        $.owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
    }

    function owner() public view returns (address) {
        return _getStorage().owner;
    }

    // ============ View ============

    function getPortfolioFactory() external view returns (address) {
        return address(_getStorage().portfolioFactory);
    }

    function maxUtilizationBps() external view returns (uint256) {
        return _getStorage().maxUtilizationBps;
    }

    function originationFeeBps() external view returns (uint256) {
        return _getStorage().originationFeeBps;
    }

    function paused() external view returns (bool) {
        return _getStorage().paused;
    }

    // ============ Internal ============

    function _getStorage() internal pure returns (LendingVaultStorage storage $) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            $.slot := position
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    modifier onlyOwner() {
        if (msg.sender != _getStorage().owner) revert NotOwner();
        _;
    }

    modifier onlyPortfolio() {
        LendingVaultStorage storage $ = _getStorage();
        require($.portfolioFactory.isPortfolio(msg.sender), "Only portfolio can call");
        _;
    }

    modifier whenNotPaused() {
        if (_getStorage().paused) revert VaultPaused();
        _;
    }
}
