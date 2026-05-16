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
    uint256 public constant DEFAULT_MAX_UTILIZATION_BPS = 8000;
    error TooHigh(uint256 value, uint256 max);
    error CombinedFeesTooHigh(uint256 combined, uint256 max);
    error InvalidMaxUtilization(uint256 value);
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner, uint256 lenderPremium, uint256 treasuryFee, uint256 zeroBalanceFee) initializer public {
        __Ownable_init(owner);
        require(lenderPremium > 0, "Lender premium must be > 0");
        require(treasuryFee > 0, "Treasury fee must be > 0");
        require(zeroBalanceFee > 0, "Zero balance fee must be > 0");
        require(zeroBalanceFee <= MAX_FEE_BPS, "Zero balance fee cannot exceed max fee");
        uint256 combined = lenderPremium + treasuryFee;
        require(combined <= MAX_FEE_BPS, CombinedFeesTooHigh(combined, MAX_FEE_BPS));
        LoanConfigData storage config = _getLoanConfig();
        config.lenderPremium = lenderPremium;
        config.treasuryFee = treasuryFee;
        config.zeroBalanceFee = zeroBalanceFee;
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
        uint256 ltv;
        uint256 maxUtilizationBps;
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

        if(collateralStorage.multiplier > 0) {
            require(multiplier <= collateralStorage.multiplier * 2, TooHigh(multiplier, collateralStorage.multiplier * 2));
        }
        collateralStorage.multiplier = multiplier;
    }
    
    function setLtv(uint256 ltv) public onlyOwner {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        require(ltv <= MAX_FEE_BPS, "LTV cannot exceed max fee");
        collateralStorage.ltv = ltv;
    }

    function getLtv() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.ltv;
    }

    function getMultiplier() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.multiplier;
    }

    function setLenderPremium(uint256 lenderPremium) public onlyOwner {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        require(lenderPremium > 0, "Lender premium must be > 0");
        uint256 combined = lenderPremium + collateralStorage.treasuryFee;
        require(combined <= MAX_FEE_BPS, CombinedFeesTooHigh(combined, MAX_FEE_BPS));
        collateralStorage.lenderPremium = lenderPremium;
    }

    function getLenderPremium() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.lenderPremium;
    }

    function setTreasuryFee(uint256 treasuryFee) public onlyOwner {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        require(treasuryFee > 0, "Treasury fee must be > 0");
        uint256 combined = collateralStorage.lenderPremium + treasuryFee;
        require(combined <= MAX_FEE_BPS, CombinedFeesTooHigh(combined, MAX_FEE_BPS));
        collateralStorage.treasuryFee = treasuryFee;
    }

    function getTreasuryFee() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.treasuryFee;
    }

    function setZeroBalanceFee(uint256 zeroBalanceFee) public onlyOwner {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        require(zeroBalanceFee > 0, "Zero balance fee must be > 0");
        require(zeroBalanceFee <= MAX_FEE_BPS, "Zero balance fee cannot exceed max fee");
        collateralStorage.zeroBalanceFee = zeroBalanceFee;
    }

    function getZeroBalanceFee() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.zeroBalanceFee;
    }

    function setMaxUtilizationBps(uint256 maxUtilizationBps) public onlyOwner {
        if (maxUtilizationBps == 0 || maxUtilizationBps > MAX_FEE_BPS) {
            revert InvalidMaxUtilization(maxUtilizationBps);
        }
        _getLoanConfig().maxUtilizationBps = maxUtilizationBps;
    }

    function getMaxUtilizationBps() public view returns (uint256) {
        uint256 stored = _getLoanConfig().maxUtilizationBps;
        return stored == 0 ? DEFAULT_MAX_UTILIZATION_BPS : stored;
    }
}