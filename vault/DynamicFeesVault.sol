// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ProtocolTimeLibrary } from "../src/libraries/ProtocolTimeLibrary.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {DebtToken} from "./DebtToken.sol";
import {IPortfolioFactory} from "../src/interfaces/IPortfolioFactory.sol";
import {console} from "forge-std/console.sol";

contract DynamicFeesVault is Initializable, ERC4626Upgradeable, UUPSUpgradeable, Ownable2StepUpgradeable {
    address public _debtToken;
    constructor() {
        _disableInitializers();
    }

    function initialize(address asset, string memory name, string memory symbol, address portfolioFactory) public initializer {
        __ERC4626_init(ERC20(asset));
        __ERC20_init(name, symbol);
        __UUPSUpgradeable_init();
        __Ownable2Step_init();
        _transferOwnership(msg.sender);
        _getDynamicFeesVaultStorage().portfolioFactory = portfolioFactory;
        _getDynamicFeesVaultStorage().debtToken = new DebtToken(address(this), asset);
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
        DebtToken debtToken = _getDynamicFeesVaultStorage().debtToken;
        return IERC20(asset()).balanceOf(address(this)) + adjustedTotalLoanedAssets - debtToken.totalAssetsPerEpoch(ProtocolTimeLibrary.epochStart(block.timestamp)) + lenderPremiumCurrentEpoch;
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
        DebtToken debtToken = $.debtToken;
        
        return debtToken.tokenClaimedPerEpoch(address(this), currentEpoch);
    }

    function lenderPremiumUnlockedThisEpoch() public returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        DebtToken debtToken = $.debtToken;
        // Call earned to ensure tokenClaimedPerEpoch is up to date for current epoch
        debtToken.earned(address(debtToken), address(this));
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        return debtToken.tokenClaimedPerEpoch(address(this), currentEpoch);
    }

    function assetsUnlockedThisEpoch() public view returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        return $.debtToken.totalAssetsUnlocked(ProtocolTimeLibrary.epochStart(block.timestamp));
    }

    function debtRepaidThisEpoch() public view returns (uint256) {
        return assetsUnlockedThisEpoch() - _getLenderPremiumUnlockedThisEpochView();
    }
    
    /**
     * @notice Gets the cumulative principal repaid up to the current moment in time
     * @dev Calculates principal repaid from checkpoint to now, including prorated current epoch
     * @dev If checkpoint is 0 (uninitialized), calculates from current epoch only
     * @return The total principal amount repaid up to now
     */
    function _getPrincipalRepaidUpToNow() internal view returns (uint256) {
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        uint256 checkpointEpoch = $.settlementCheckpointEpoch;
        address debtTokenAddress = address($.debtToken);
        uint256 totalPrincipalRepaid = 0;
        
        // If checkpoint is 0, we only calculate current epoch (will be synced on first update)
        // Otherwise, calculate from checkpoint epoch to current epoch (inclusive)
        uint256 startEpoch = checkpointEpoch > 0 ? checkpointEpoch : currentEpoch;
        
        // Calculate principal repaid for epochs from start to current (inclusive)
        for (uint256 epoch = startEpoch; epoch <= currentEpoch; epoch += ProtocolTimeLibrary.WEEK) {
            uint256 assetsUnlocked = $.debtToken.totalAssetsUnlocked(epoch);
            if (assetsUnlocked == 0) continue;
            
            uint256 lenderPremium;
            if (epoch == currentEpoch) {
                // For current epoch, use the unlocked premium (view-safe, reads from storage)
                // Note: This may be slightly stale if earned() hasn't been called recently
                lenderPremium = _getLenderPremiumUnlockedThisEpochView();
            } else {
                // For past epochs, get the final claimed amount
                // lenderPremium = $.debtToken.tokenClaimedPerEpoch(address(this), debtTokenAddress, epoch);
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
        uint256 earned = $.debtToken.getReward(address(this));
        $.totalLoanedAssets -= earned;
        $.settlementCheckpointEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        console.log("totalLoanedAssets", $.totalLoanedAssets);
        console.log("earned", earned);
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

    function borrow(uint256 amount) onlyPortfolio public {
        _updateSettlementCheckpoint();
        _updateUserDebtBalance(msg.sender);
        // only allow borrowing if the utilization percent is less than 80%
        require(getUtilizationPercent() < 8000, "Utilization exceeds 80%");
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        IERC20(asset()).transfer(msg.sender, amount);
        $.debtBalance[msg.sender] += amount;
        $.totalLoanedAssets += amount;
        _updateUserDebtBalance(msg.sender);
    }

    function repay(uint256 amount) public {
        _updateSettlementCheckpoint();
        _updateUserDebtBalance(msg.sender);
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        uint256 debtBalance = $.debtBalance[msg.sender];
        uint256 amountToRepay = debtBalance < amount ? debtBalance : amount;
        IERC20(asset()).transferFrom(msg.sender, address(this), amountToRepay);
        $.totalLoanedAssets -= amountToRepay;
        $.debtBalance[msg.sender] -= amountToRepay;
        _updateUserDebtBalance(msg.sender);
    }

    function repayWithRewards(uint256 amount) public {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();

        // Update settlement checkpoint to sync totalLoanedAssets with current repayments
        _updateSettlementCheckpoint();
        
        // Transfer assets from user to vault
        IERC20(asset()).transferFrom(msg.sender, address(this), amount);
        
        // Mint debt tokens (this adds to totalAssetsPerEpoch and creates a new checkpoint)
        $.debtToken.mint(msg.sender, amount);
        
        // Update user debt balance to apply earned rewards to debt
        // This will reduce debtBalance and totalLoanedAssets appropriately
        // If earned > debtBalance, the excess will be minted as vault shares
        _updateUserDebtBalance(msg.sender);
    }

    function updateUserDebtBalance(address borrower) public {
        _updateUserDebtBalance(borrower);
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
        uint256 currentDebtBalance = $.debtBalance[borrower];

        console.log("=========e111111 arned for itme", earned);
        
        // if earned is more than the debt balance, give user the difference via minting vault shares
        // and set debt balance to 0 (debt is fully paid off by rewards)
        if (earned > currentDebtBalance) {
            uint256 difference = earned - currentDebtBalance;
            _mint(borrower, difference);
            console.log("minted", difference);
            console.log("debt balance", $.debtBalance[borrower]);
            $.debtBalance[borrower] = 0;
            console.log("totalLoanedAssets", $.totalLoanedAssets);
            console.log("currentDebtBalance", currentDebtBalance);
        } else if (earned > 0) {
            $.debtBalance[borrower] -= earned;
        }

        console.log("totalLoanedAssets", $.totalLoanedAssets);
        console.log("debtBalance", $.debtBalance[borrower]);
        console.log("earned", earned);
        console.log("currentDebtBalance", currentDebtBalance);
        // Otherwise, debt balance remains unchanged (earned rewards don't fully cover the debt)
        // The debt balance will be reduced when the user calls repay()
        $.debtToken.rebalance();
    }
    
    /**
     * @dev Override _deposit to automatically update settlement checkpoint and rebalance
     * @dev This ensures totalAssets() is accurate in real-time and vault ratio is maintained when users deposit
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        // Update settlement checkpoint to sync totalLoanedAssets with current repayments (real-time)
        _updateSettlementCheckpoint();
        
        // Call parent implementation
        super._deposit(caller, receiver, assets, shares);
        
        // Rebalance DebtToken to maintain vault ratio after deposit
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        $.debtToken.rebalance();
    }

    /**
     * @dev Override _withdraw to automatically update settlement checkpoint and rebalance
     * @dev This ensures totalAssets() is accurate in real-time and vault ratio is maintained when users withdraw
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        // Update settlement checkpoint to sync totalLoanedAssets with current repayments (real-time)
        _updateSettlementCheckpoint();
        
        // Call parent implementation
        super._withdraw(caller, receiver, owner, assets, shares);
        
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

    function getUtilizationPercent() public view returns (uint256) {
        // assets borrowed / total assets (in basis points, where 10000 = 100%)
        uint256 total = totalAssets();
        if (total == 0) return 0;
        uint256 loaned = totalLoanedAssets();
        uint256 utilization = (loaned * 10000) / total;
        return utilization;
    }
}