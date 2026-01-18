// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.27;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ProtocolTimeLibrary } from "../src/libraries/ProtocolTimeLibrary.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DebtToken} from "./DebtToken.sol";
import {FeeCalculator} from "./FeeCalculator.sol";
import {IPortfolioFactory} from "../src/interfaces/IPortfolioFactory.sol";

contract DynamicFeesVault is Initializable, ERC4626Upgradeable, UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @notice Maximum number of epochs to iterate through in loops to prevent DOS
    uint256 public constant MAX_EPOCH_ITERATIONS = 52; // ~1 year of weeks

    // ============ Events ============
    event Synced(uint256 indexed epoch, uint256 totalLoanedAssets, uint256 principalRepaid);
    event Paused(address indexed pauser);
    event Unpaused(address indexed owner);
    event PauserAdded(address indexed pauser);
    event PauserRemoved(address indexed pauser);
    event DebtBalanceUpdated(address indexed borrower, uint256 oldBalance, uint256 newBalance, uint256 rewardsApplied);

    // ============ Errors ============
    error ContractPaused();
    error NotPauser();
    error AlreadyPauser();
    error NotAPauser();

    constructor() {
        _disableInitializers();
    }

    function initialize(address asset, string memory name, string memory symbol, address portfolioFactory) public initializer {
        __ERC4626_init(ERC20(asset));
        __ERC20_init(name, symbol);
        __UUPSUpgradeable_init();
        __Ownable2Step_init();
        _transferOwnership(msg.sender);
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        $.portfolioFactory = portfolioFactory;

        // Deploy the default fee calculator
        FeeCalculator feeCalc = new FeeCalculator();

        // Deploy DebtToken implementation
        DebtToken debtTokenImpl = new DebtToken();

        // Deploy DebtToken proxy and initialize it
        bytes memory initData = abi.encodeWithSelector(
            DebtToken.initialize.selector,
            address(this),      // vault
            address(feeCalc),   // feeCalculator
            msg.sender          // owner (same as vault owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(debtTokenImpl), initData);
        $.debtToken = DebtToken(address(proxy));
    }

    function totalLoanedAssets() public view returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        return $.totalLoanedAssets;
    }

    function totalAssets() public view override returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        
        // Calculate principal repaid up to now (real-time)
        uint256 currentPrincipalRepaid = _getPrincipalRepaidUpToNow();
        
        // Calculate how much principal has been repaid since the last checkpoint
        // Use checked subtraction to prevent underflow (shouldn't happen in normal operation)
        uint256 principalRepaidSinceCheckpoint = currentPrincipalRepaid >= $.principalRepaidAtCheckpoint
            ? currentPrincipalRepaid - $.principalRepaidAtCheckpoint
            : 0;
        
        // Adjust totalLoanedAssets by subtracting principal repaid since checkpoint
        uint256 adjustedTotalLoanedAssets = $.totalLoanedAssets > principalRepaidSinceCheckpoint 
            ? $.totalLoanedAssets - principalRepaidSinceCheckpoint 
            : 0;
        
        // Get current lender premium (earned income) - view-safe version
        uint256 lenderPremiumCurrentEpoch = _getLenderPremiumUnlockedThisEpochView();
        DebtToken _debtToken = _getDynamicFeesVaultStorage().debtToken;
        return IERC20(asset()).balanceOf(address(this)) + adjustedTotalLoanedAssets - _debtToken.totalAssetsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp)) + lenderPremiumCurrentEpoch;
    }
    // named storage slot for the dynamic fees vault
    bytes32 private constant DYNAMIC_FEES_VAULT_STORAGE_POSITION = keccak256("dynamic.fees.vault");
    struct DynamicFeesVaultStorage {
        uint256 totalLoanedAssets; // total assets currently loaned out to users
        mapping(address => uint256) debtBalance; // debt balance of each user
        uint256 originationFeeBasisPoints; // basis points for the origination fee
        uint256 settlementCheckpointEpoch; // epoch of the last settlement checkpoint
        uint256 principalRepaidAtCheckpoint; // cumulative principal repaid at the checkpoint
        address portfolioFactory; // portfolio factory address
        DebtToken debtToken; // debt token address
        bool paused; // whether the vault is paused
        mapping(address => bool) pausers; // addresses that can pause the vault
    }

    function _getDynamicFeesVaultStorage() private pure returns (DynamicFeesVaultStorage storage $) {
        bytes32 position = DYNAMIC_FEES_VAULT_STORAGE_POSITION;
        assembly {
            $.slot := position
        }
    }


    /**
     * @notice Gets lender premium unlocked this epoch (view-safe, may be slightly stale for current epoch)
     * @dev This is a view-safe version that reads directly from storage without side effects
     * @dev For non-view contexts, use the state-modifying version in DebtToken
     */
    function _getLenderPremiumUnlockedThisEpochView() internal view returns (uint256) {
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        // Read directly from storage to avoid side effects in view functions
        // Note: This may be slightly stale for the current epoch if earned() hasn't been called recently
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();

        return $.debtToken.tokenClaimedPerEpoch(address(this), currentEpoch);
    }

    function lenderPremiumUnlockedThisEpoch() public returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        // Call earned to ensure tokenClaimedPerEpoch is up to date for current epoch
        $.debtToken.earned(address(this));
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        return $.debtToken.tokenClaimedPerEpoch(address(this), currentEpoch);
    }

    function assetsUnlockedThisEpoch() public view returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        return $.debtToken.totalAssets(ProtocolTimeLibrary.epochStart(block.timestamp));
    }

    function debtRepaidThisEpoch() public view returns (uint256) {
        return assetsUnlockedThisEpoch() - _getLenderPremiumUnlockedThisEpochView();
    }
    
    /**
     * @notice Gets the cumulative principal repaid up to the current moment in time
     * @dev Calculates principal repaid from checkpoint to now, including prorated current epoch
     * @dev If checkpoint is 0 (uninitialized), calculates from current epoch only
     * @dev NOTE: Protocol should not operate in epoch 0 - always start from epoch 1 or later
     * @return The total principal amount repaid up to now
     */
    function _getPrincipalRepaidUpToNow() internal view returns (uint256) {
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        uint256 checkpointEpoch = $.settlementCheckpointEpoch;
        uint256 totalPrincipalRepaid = 0;

        // If checkpoint is 0 (uninitialized), calculate from current epoch only
        // Otherwise, calculate from checkpoint epoch to current epoch (inclusive)
        uint256 startEpoch = checkpointEpoch > 0 ? checkpointEpoch : currentEpoch;
        
        // Calculate principal repaid for epochs from start to current (inclusive)
        // Limit iterations to prevent DOS attacks from stale checkpoints
        uint256 iterations = 0;
        for (uint256 epoch = startEpoch; epoch <= currentEpoch && iterations < MAX_EPOCH_ITERATIONS; epoch += ProtocolTimeLibrary.WEEK) {
            iterations++;
            uint256 assetsUnlocked = $.debtToken.totalAssets(epoch);
            if (assetsUnlocked == 0) continue;
            
            uint256 lenderPremium;
            if (epoch == currentEpoch) {
                // For current epoch, use the unlocked premium (view-safe, reads from storage)
                // Note: This may be slightly stale if earned() hasn't been called recently
                lenderPremium = _getLenderPremiumUnlockedThisEpochView();
            } else {
                // For past epochs, use the final claimed amount for the vault
                lenderPremium = $.debtToken.tokenClaimedPerEpoch(address(this), epoch);
            }
            
            uint256 principalRepaid = assetsUnlocked > lenderPremium ? assetsUnlocked - lenderPremium : 0;
            totalPrincipalRepaid += principalRepaid;
        }
        
        return totalPrincipalRepaid;
    }
    
    /**
     * @notice Updates the settlement checkpoint to the current state
     * @dev This should be called in hooks to sync totalLoanedAssets with actual repayments
     */
    function _updateSettlementCheckpoint() internal {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        // Update vault rewards to ensure tokenClaimedPerEpoch is up to date
        $.debtToken.getReward(address(this));

        uint256 currentPrincipalRepaid = _getPrincipalRepaidUpToNow();
        uint256 principalRepaidSinceCheckpoint = currentPrincipalRepaid >= $.principalRepaidAtCheckpoint
            ? currentPrincipalRepaid - $.principalRepaidAtCheckpoint
            : 0;

        if (principalRepaidSinceCheckpoint > 0) {
            $.totalLoanedAssets = $.totalLoanedAssets > principalRepaidSinceCheckpoint
                ? $.totalLoanedAssets - principalRepaidSinceCheckpoint
                : 0;
        }

        $.principalRepaidAtCheckpoint = currentPrincipalRepaid;
        $.settlementCheckpointEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
    }
    
    /**
     * @notice Gets the settlement checkpoint information
     * @return checkpointEpoch The epoch of the last checkpoint
     * @return principalRepaidAtCheckpoint The principal repaid amount at the checkpoint
     */
    function getSettlementCheckpoint() public view returns (uint256 checkpointEpoch, uint256 principalRepaidAtCheckpoint) {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        return ($.settlementCheckpointEpoch, $.principalRepaidAtCheckpoint);
    }
    
    /**
     * @dev This function is used to authorize upgrades to the contract.
     *      It restricts the upgradeability to only the contract owner.
     * @param newImplementation The address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function decreaseTotalLoanedAssets(uint256 amount) public {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        require(msg.sender == address($.debtToken), "Only debt token can call this function");
        $.totalLoanedAssets -= amount;
    }

    function borrow(uint256 amount) external onlyPortfolio whenNotPaused {
        _updateSettlementCheckpoint();
        _updateUserDebtBalance(msg.sender);

        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();

        // Check post-borrow utilization to prevent pushing utilization above 80%
        uint256 total = totalAssets();
        uint256 postBorrowLoaned = $.totalLoanedAssets + amount;
        uint256 postBorrowUtilization = total > 0 ? (postBorrowLoaned * 10000) / total : 0;
        require(postBorrowUtilization < 8000, "Borrow would exceed 80% utilization");

        IERC20(asset()).transfer(msg.sender, amount);
        $.debtBalance[msg.sender] += amount;
        $.totalLoanedAssets += amount;
        _updateUserDebtBalance(msg.sender);
        _updateSettlementCheckpoint();
    }

    function repay(uint256 amount) external whenNotPaused {
        _updateSettlementCheckpoint();
        _updateUserDebtBalance(msg.sender);
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        uint256 debtBalance = $.debtBalance[msg.sender];
        uint256 amountToRepay = debtBalance < amount ? debtBalance : amount;
        IERC20(asset()).transferFrom(msg.sender, address(this), amountToRepay);
        $.totalLoanedAssets -= amountToRepay;
        $.debtBalance[msg.sender] -= amountToRepay;
        _updateUserDebtBalance(msg.sender);
        _updateSettlementCheckpoint();
    }

    function repayWithRewards(uint256 amount) external whenNotPaused {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();

        // Update settlement checkpoint to sync totalLoanedAssets with current repayments
        _updateSettlementCheckpoint();

        // Transfer assets from user to vault
        IERC20(asset()).transferFrom(msg.sender, address(this), amount);

        // Mint debt tokens (this adds to totalAssetsPerEpoch and triggers rebalance)
        // The lender/borrower split is based on current utilization at time of deposit
        $.debtToken.mint(msg.sender, amount);

        // Update user debt balance to apply earned rewards to debt
        // If earned > debtBalance, the excess will be minted as vault shares
        _updateUserDebtBalance(msg.sender);
        _updateSettlementCheckpoint();
    }

    function updateUserDebtBalance(address borrower) public {
        _updateSettlementCheckpoint();
        _updateUserDebtBalance(borrower);
        _updateSettlementCheckpoint();
    }

    /**
     * @notice Syncs the vault's settlement checkpoint without affecting any user's debt balance
     * @dev This syncs totalLoanedAssets with actual repayments from vested rewards
     * @dev Useful for keeping vault state accurate for view functions and triggering settlements
     */
    function sync() public {
        _updateSettlementCheckpoint();
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        emit Synced(
            ProtocolTimeLibrary.epochStart(block.timestamp),
            $.totalLoanedAssets,
            $.principalRepaidAtCheckpoint
        );
    }

    // ============ Pause Mechanism ============

    /**
     * @notice Pauses the vault - can be called by authorized pausers
     * @dev Only affects borrow, repay, repayWithRewards, deposit, and withdraw
     */
    function pause() external {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        if (!$.pausers[msg.sender] && msg.sender != owner()) revert NotPauser();
        $.paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpauses the vault - can only be called by owner
     */
    function unpause() external onlyOwner {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        $.paused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Adds an address as an authorized pauser
     * @param pauser The address to add as a pauser
     */
    function addPauser(address pauser) external onlyOwner {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        if ($.pausers[pauser]) revert AlreadyPauser();
        $.pausers[pauser] = true;
        emit PauserAdded(pauser);
    }

    /**
     * @notice Removes an address from authorized pausers
     * @param pauser The address to remove as a pauser
     */
    function removePauser(address pauser) external onlyOwner {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        if (!$.pausers[pauser]) revert NotAPauser();
        $.pausers[pauser] = false;
        emit PauserRemoved(pauser);
    }

    /**
     * @notice Checks if an address is an authorized pauser
     * @param account The address to check
     * @return True if the address is a pauser
     */
    function isPauser(address account) public view returns (bool) {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        return $.pausers[account];
    }

    /**
     * @notice Returns whether the vault is currently paused
     * @return True if paused
     */
    function paused() public view returns (bool) {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        return $.paused;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is not paused
     */
    modifier whenNotPaused() {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        if ($.paused) revert ContractPaused();
        _;
    }

    /// @notice Get the current debt balance for a borrower
    /// @param borrower The address of the borrower
    /// @return The current debt balance
    function getDebtBalance(address borrower) public view returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        return $.debtBalance[borrower];
    }
    /**
     * @notice Updates the debt balance of a user
     * @dev This function updates the debt balance of a user by accounting for earned rewards
     * @dev If earned rewards exceed the debt balance, the user receives the excess as vault shares
     * @dev Otherwise, the debt balance remains unchanged (preserving the borrowed amount)
     * @param borrower The address of the borrower
     */
    function _updateUserDebtBalance(address borrower) internal {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        // claimDebtRewards calls earned() which already prevents double-counting via tokenClaimedPerEpoch
        // It only returns new rewards that haven't been claimed yet for each epoch
        uint256 earned = $.debtToken.getReward(borrower);
        uint256 oldDebtBalance = $.debtBalance[borrower];

        // NOTE: We do NOT reduce totalLoanedAssets here because _updateSettlementCheckpoint()
        // already handles the global accounting by calculating (totalAssets - lenderPremium).
        // This function only updates the individual user's debt balance.

        // if earned is more than the debt balance, give user the difference via minting vault shares
        // and set debt balance to 0 (debt is fully paid off by rewards)
        if (earned > oldDebtBalance) {
            uint256 difference = earned - oldDebtBalance;
            _mint(borrower, difference);
            $.debtBalance[borrower] = 0;
        } else if (earned > 0) {
            $.debtBalance[borrower] -= earned;
        }

        // Emit event if debt balance changed
        if (earned > 0) {
            emit DebtBalanceUpdated(borrower, oldDebtBalance, $.debtBalance[borrower], earned);
        }

        // Otherwise, debt balance remains unchanged (earned rewards don't fully cover the debt)
        // The debt balance will be reduced when the user calls repay()
        $.debtToken.rebalance();
    }
    
    /**
     * @dev Override _deposit to automatically update settlement checkpoint and rebalance
     * @dev This ensures totalAssets() is accurate in real-time and vault ratio is maintained when users deposit
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        if ($.paused) revert ContractPaused();

        // Update settlement checkpoint to sync totalLoanedAssets with current repayments (real-time)
        _updateSettlementCheckpoint();
        
        // Call parent implementation
        super._deposit(caller, receiver, assets, shares);

        // Rebalance DebtToken to maintain vault ratio after deposit
        $.debtToken.rebalance();
    }

    /**
     * @dev Override _withdraw to automatically update settlement checkpoint and rebalance
     * @dev This ensures totalAssets() is accurate in real-time and vault ratio is maintained when users withdraw
     */
    function _withdraw(
        address caller,
        address receiver,
        address _owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        if ($.paused) revert ContractPaused();

        // Update settlement checkpoint to sync totalLoanedAssets with current repayments (real-time)
        _updateSettlementCheckpoint();
        
        // Call parent implementation
        super._withdraw(caller, receiver, _owner, assets, shares);
        
        // Rebalance DebtToken to maintain vault ratio after withdrawal
        $.debtToken.rebalance();
    }

    modifier onlyPortfolio() {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        require(IPortfolioFactory($.portfolioFactory).isPortfolio(msg.sender), "Only portfolio can call this function");
        _;
    }
    
    function debtToken() public view returns (DebtToken) {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        return $.debtToken;
    }

    /**
     * @notice Returns the current fee calculator address used by the DebtToken
     * @return The fee calculator contract address
     */
    function feeCalculator() public view returns (address) {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        return $.debtToken.feeCalculator();
    }

    function getUtilizationPercent() public view returns (uint256) {
        // assets borrowed / total assets (in basis points, where 10000 = 100%)
        uint256 total = totalAssets();
        if (total == 0) return 0;
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        uint256 utilization = ($.totalLoanedAssets * 10000) / total;
        return utilization;
    }
}