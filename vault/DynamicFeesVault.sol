// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ProtocolTimeLibrary } from "./libraries/ProtocolTimeLibrary.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {DebtToken} from "./DebtToken.sol";

contract DynamicFeesVault is Initializable, ERC4626Upgradeable, UUPSUpgradeable, Ownable2StepUpgradeable {
    DebtToken public _debtToken;

    constructor() {
        _disableInitializers();
        _debtToken = new DebtToken(address(this));
    }

    function initialize(address asset, address loan, string memory name, string memory symbol, address portfolioFactory) public initializer {
        __ERC4626_init(ERC20(asset));
        __ERC20_init(name, symbol);
        __UUPSUpgradeable_init();
        __Ownable2Step_init(msg.sender);
    }




    function epochRewardsLocked() public view returns (uint256) {
        uint256 epochTimeRemaining = ProtocolTimeLibrary.epochNext(block.timestamp) - block.timestamp;
        uint256 epochRewards = _loanContract.lastEpochReward();

        // percentage of epoch rewards based on time elapsed
        return  epochTimeRemaining * _debtToken.convertToShares(epochRewards) / ProtocolTimeLibrary.WEEK;
    }

    function totalAssets() public view override returns (uint256) {
        return _asset.balanceOf(address(this)) + totalLoanedAssets() - epochRewardsLocked(); 
    }

    // named storage slot for the dynamic fees vault
    bytes32 private constant DYNAMIC_FEES_VAULT_STORAGE_POSITION = keccak256("dynamic.fees.vault");
    struct DynamicFeesVaultStorage {
        uint256 totalLoanedAssets; // total assets currently loaned out to users
        uint256 originationFeeBasisPoints; // basis points for the origination fee
    }

    function _getDynamicFeesVaultStorage() private pure returns (DynamicFeesVaultStorage storage $) {
        assembly {
            $.slot := DYNAMIC_FEES_VAULT_STORAGE_POSITION
        }
    }

    /**
     * @notice Returns the total assets currently loaned out to users
     * @return The total assets currently loaned out to users
     * @dev This function returns the total assets (total loaned assets, and the assets accrued from the debt token)
     */
    function totalLoanedAssets() internal view returns (uint256) {
        // get the total earned for the vault
        return _getDynamicFeesVaultStorage().totalLoanedAssets;
    }

    function originationFeeBasisPoints() internal view returns (uint256) {
        return _getDynamicFeesVaultStorage().originationFeeBasisPoints;
    }
    
    
    /**
     * @dev This function is used to authorize upgrades to the contract.
     *      It restricts the upgradeability to only the contract owner.
     * @param newImplementation The address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function totalAssets() public view override virtual returns (uint256) {
        return _asset.balanceOf(address(this)) + _getDynamicFeeStorage().totalLoanedAssets + rewardsAccrued;
    }

    function borrow(uint256 amount) public {
        _asset.transferFrom(msg.sender, address(this), amount);
        _getDynamicFeesVaultStorage().totalLoanedAssets += amount;
    }

    function repay(uint256 amount) public {
        _asset.transferFrom(msg.sender, address(this), amount);
        _getDynamicFeeStorage().totalLoanedAssets -= amount;
    }

    function payWithRewards(uint256 amount) public {
        _debtToken.mint(msg.sender, amount);
    }
}