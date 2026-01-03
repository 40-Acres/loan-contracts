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

contract DynamicFeesVault is Initializable, ERC4626Upgradeable, UUPSUpgradeable, Ownable2StepUpgradeable {
    DebtToken public _debtToken;

    constructor() {
        _disableInitializers();
    }

    function initialize(address asset, address /* loan */, string memory name, string memory symbol, address /* portfolioFactory */) public initializer {
        __ERC4626_init(ERC20(asset));
        __ERC20_init(name, symbol);
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        _debtToken = new DebtToken(address(this));
    }

    function totalLoanedAssets() public view returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        return $.totalLoanedAssets;
    }
    

    function totalAssets() public view override returns (uint256) {
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        
        uint256 assetsRepaidCurrentEpoch = _debtToken.totalAssetsUnlocked(currentEpoch);
        // Read directly from mapping to avoid state modification in view function
        // Note: This may return a stale value if earned() hasn't been called recently
        address debtTokenAddress = address(_debtToken);
        uint256 lenderPremiumCurrentEpoch = _debtToken.tokenClaimedPerEpoch(address(this), debtTokenAddress, currentEpoch);
        
        // Calculate principal repaid in current epoch
        uint256 principalRepaidCurrentEpoch = assetsRepaidCurrentEpoch > lenderPremiumCurrentEpoch 
            ? assetsRepaidCurrentEpoch - lenderPremiumCurrentEpoch 
            : 0;
        
        // For past epochs that haven't been settled, we need to account for them
        // But since we can't modify state in a view function, we'll handle this in settlePreviousEpoch
        // For now, we only subtract current epoch repayments
        return IERC20(asset()).balanceOf(address(this)) + totalLoanedAssets() - principalRepaidCurrentEpoch + lenderPremiumCurrentEpoch;
    }

    // named storage slot for the dynamic fees vault
    bytes32 private constant DYNAMIC_FEES_VAULT_STORAGE_POSITION = keccak256("dynamic.fees.vault");
    struct DynamicFeesVaultStorage {
        uint256 totalLoanedAssets; // total assets currently loaned out to users
        uint256 originationFeeBasisPoints; // basis points for the origination fee
        uint256 lastSettledEpoch; // last epoch for which totalLoanedAssets was updated
        uint256 cumulativePrincipalRepaid; // cumulative principal repaid across all settled epochs
    }

    function _getDynamicFeesVaultStorage() private pure returns (DynamicFeesVaultStorage storage $) {
        bytes32 position = DYNAMIC_FEES_VAULT_STORAGE_POSITION;
        assembly {
            $.slot := position
        }
    }


    function lenderPremiumUnlockedThisEpoch() public returns (uint256) {
        return _debtToken.lenderPremiumUnlockedThisEpoch();
    }

    function assetsUnlockedThisEpoch() public view returns (uint256) {
        return _debtToken.totalAssetsUnlocked(ProtocolTimeLibrary.epochStart(block.timestamp));
    }

    function debtRepaidThisEpoch() public returns (uint256) {
        return assetsUnlockedThisEpoch() - lenderPremiumUnlockedThisEpoch();
    }
    
    /**
     * @notice Gets the principal repaid (assets - premium) for a specific epoch
     * @param epoch The epoch to query
     * @return The principal amount repaid in that epoch
     */
    function getPrincipalRepaidForEpoch(uint256 epoch) public returns (uint256) {
        uint256 assetsUnlocked = _debtToken.totalAssetsUnlocked(epoch);
        // For past epochs, we need to get the final claimed premium
        // For current epoch, use the unlocked premium (this may modify state)
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        uint256 lenderPremium;
        // In DebtToken, lenderPremiumUnlockedThisEpoch uses tokenClaimedPerEpoch[vault][address(this)][epoch]
        // where address(this) in DebtToken context is the DebtToken contract address
        // So we use the DebtToken address as the token identifier
        address debtTokenAddress = address(_debtToken);
        if (epoch == currentEpoch) {
            lenderPremium = _debtToken.lenderPremiumUnlockedThisEpoch();
        } else {
            // For past epochs, get the final claimed amount
            lenderPremium = _debtToken.tokenClaimedPerEpoch(address(this), debtTokenAddress, epoch);
        }
        return assetsUnlocked > lenderPremium ? assetsUnlocked - lenderPremium : 0;
    }
    
    /**
     * @notice Settles the previous epoch by updating totalLoanedAssets with principal repaid
     * @dev This should be called when a new epoch starts to ensure totalLoanedAssets is accurate
     * @dev Can be called by anyone, but is idempotent (won't settle the same epoch twice)
     * @dev For past epochs, the premium should already be calculated and stored in tokenClaimedPerEpoch
     */
    function settlePreviousEpoch() public {
        uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        
        // Calculate previous epoch
        uint256 previousEpoch = currentEpoch - ProtocolTimeLibrary.WEEK;
        
        // Only settle if we haven't settled this epoch yet
        if ($.lastSettledEpoch >= previousEpoch) {
            return; // Already settled
        }
        
        // Calculate principal repaid in previous epoch
        // For past epochs, totalAssetsUnlocked returns the full amount (not prorated)
        uint256 assetsUnlocked = _debtToken.totalAssetsUnlocked(previousEpoch);
        
        // Get the lender premium for that epoch
        // In DebtToken, lenderPremiumUnlockedThisEpoch uses tokenClaimedPerEpoch[vault][address(this)][epoch]
        // where address(this) in DebtToken context is the DebtToken contract address
        // So we use the DebtToken address as the token identifier
        address debtTokenAddress = address(_debtToken);
        uint256 lenderPremium = _debtToken.tokenClaimedPerEpoch(address(this), debtTokenAddress, previousEpoch);
        
        // Calculate principal repaid (assets - premium)
        uint256 principalRepaid = assetsUnlocked > lenderPremium ? assetsUnlocked - lenderPremium : 0;
        
        // Update totalLoanedAssets by the principal repaid
        if (principalRepaid > 0) {
            $.totalLoanedAssets -= principalRepaid;
            $.cumulativePrincipalRepaid += principalRepaid;
        }
        
        // Update last settled epoch
        $.lastSettledEpoch = previousEpoch;
    }
    
    /**
     * @notice Gets the last settled epoch
     * @return The epoch number that was last settled
     */
    function getLastSettledEpoch() public view returns (uint256) {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        return $.lastSettledEpoch;
    }
    
    /**
     * @notice Gets the settlement checkpoint (last settled epoch and cumulative principal repaid)
     * @return checkpointEpoch The last epoch that was settled
     * @return principalRepaid The cumulative principal repaid up to the checkpoint epoch
     */
    function getSettlementCheckpoint() public view returns (uint256 checkpointEpoch, uint256 principalRepaid) {
        DynamicFeesVaultStorage storage $ = _getDynamicFeesVaultStorage();
        checkpointEpoch = $.lastSettledEpoch;
        principalRepaid = $.cumulativePrincipalRepaid;
    }
    
    /**
     * @dev This function is used to authorize upgrades to the contract.
     *      It restricts the upgradeability to only the contract owner.
     * @param newImplementation The address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function decreaseTotalLoanedAssets(uint256 amount) public {
        require(msg.sender == address(_debtToken), "Only debt token can call this function");
        _getDynamicFeesVaultStorage().totalLoanedAssets -= amount;
    }

    function borrow(uint256 amount, address to) public {
        IERC20(asset()).transfer(to, amount);
        _getDynamicFeesVaultStorage().totalLoanedAssets += amount;
    }

    function repay(uint256 amount) public {
        IERC20(asset()).transferFrom(msg.sender, address(this), amount);
        _getDynamicFeesVaultStorage().totalLoanedAssets -= amount;
    }

    function payWithRewards(uint256 amount) public {
        // TODO: handle the users debt token earned rewards here

        _debtToken.mint(msg.sender, amount);
    }

    /**
     * @dev Override _deposit to automatically settle previous epoch before deposits
     * @dev This ensures totalAssets() is accurate when users deposit
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        // Settle previous epoch if needed (idempotent, so safe to call)
        settlePreviousEpoch();
        
        // Call parent implementation
        super._deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Override _withdraw to automatically settle previous epoch before withdrawals
     * @dev This ensures totalAssets() is accurate when users withdraw
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        // Settle previous epoch if needed (idempotent, so safe to call)
        settlePreviousEpoch();
        
        // Call parent implementation
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // modifier onlyPortfolio() {
    //     require(IPortfolioFactory(portfolioFactory).isPortfolio(msg.sender), "Only portfolio can call this function");
    //     _;
    // }
    
}