// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ILoanConfig} from "./ILoanConfig.sol";

/**
 * @title LoanConfig
 */
contract LoanConfig is ILoanConfig, Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    uint256 public constant MAX_FEE_BPS = 100_00; // 100% in basis points

    error TooHigh(uint256 value, uint256 max);
    constructor() {
        _disableInitializers();
    }
    
    function initialize(address owner) initializer public {
        __Ownable_init(owner); 
    }
    
    /**
     * @dev This function is used to authorize upgrades to the contract.
     *      It restricts the upgradeability to only the contract owner.
     * @param newImplementation The address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    // Token storage data using named storage slot
    struct LoanConfigData {
        uint256 rewardsRate;
        uint256 lenderPremium;
        uint256 treasuryFee;
        uint256 zeroBalanceFee;
        uint256 multiplier;
    }


    // Named storage slot for account data
    bytes32 private constant ACCOUNT_STORAGE_POSITION = keccak256("storage.LoanConfig");

    /**
     * @dev Get token storage data from named storage slot
     */
    function _getLoanConfig() internal pure returns (LoanConfigData storage collateralStorage) {
        bytes32 position = ACCOUNT_STORAGE_POSITION;
        assembly {
            collateralStorage.slot := position
        }
    }

    function getActiveRates() public view returns (uint256 lenderPremium, uint256 treasuryFee) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return (collateralStorage.lenderPremium, collateralStorage.treasuryFee);
    }

    function setRewardsRate(uint256 rewardsRate) public onlyOwner {
        LoanConfigData storage collateralStorage = _getLoanConfig();

        // require rewards rate is less than double the current rewards rate to prevent drastic changes
        // also take into account the rewards rate could be 0, so set a minimum rewards rate of 100 basis points (1%) to prevent division by zero errors in the rewards calculation
        if(collateralStorage.rewardsRate > 0) {
            require(rewardsRate <= collateralStorage.rewardsRate * 2, TooHigh(rewardsRate, collateralStorage.rewardsRate * 2));
        }
        collateralStorage.rewardsRate = rewardsRate;
    }

    function getRewardsRate() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.rewardsRate;
    }

    function setMultiplier(uint256 multiplier) public onlyOwner {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        collateralStorage.multiplier = multiplier;
    }

    function getMultiplier() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.multiplier;
    }

    function setLenderPremium(uint256 lenderPremium) public onlyOwner {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        require(lenderPremium <= MAX_FEE_BPS, "Lender premium cannot exceed max fee");
        collateralStorage.lenderPremium = lenderPremium;
    }

    function getLenderPremium() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.lenderPremium;
    }

    function setTreasuryFee(uint256 treasuryFee) public onlyOwner {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        require(treasuryFee <= MAX_FEE_BPS, "Treasury fee cannot exceed max fee");
        collateralStorage.treasuryFee = treasuryFee;
    }

    function getTreasuryFee() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.treasuryFee;
    }

    function setZeroBalanceFee(uint256 zeroBalanceFee) public onlyOwner {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        require(zeroBalanceFee <= MAX_FEE_BPS, "Zero balance fee cannot exceed max fee");
        collateralStorage.zeroBalanceFee = zeroBalanceFee;
    }

    function getZeroBalanceFee() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.zeroBalanceFee;
    }
}