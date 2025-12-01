// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/**
 * @title LoanConfig
 */
contract LoanConfig is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    constructor() {
        _disableInitializers();
    }
    
    function initialize() initializer public {
        __Ownable_init(msg.sender); 
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
        collateralStorage.rewardsRate = rewardsRate;
    }

    function getRewardsRate() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.rewardsRate;
    }

    function setLenderPremium(uint256 lenderPremium) public onlyOwner {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        collateralStorage.lenderPremium = lenderPremium;
    }

    function getLenderPremium() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.lenderPremium;
    }

    function setTreasuryFee(uint256 treasuryFee) public onlyOwner {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        collateralStorage.treasuryFee = treasuryFee;
    }

    function getTreasuryFee() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.treasuryFee;
    }

    function setZeroBalanceFee(uint256 zeroBalanceFee) public onlyOwner {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        collateralStorage.zeroBalanceFee = zeroBalanceFee;
    }

    function getZeroBalanceFee() public view returns (uint256) {
        LoanConfigData storage collateralStorage = _getLoanConfig();
        return collateralStorage.zeroBalanceFee;
    }
}