

pragma solidity ^0.8.20;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

abstract contract RateStorage is Ownable2StepUpgradeable {
    /// @custom:storage-location erc7201:storage:RateStorage
    struct RateStorageStruct {
        uint256 _zeroBalanceFee;
        uint256 _rewardsRate; 
        uint256 _lenderPremium; 
        uint256 _protocolFee;
        uint256 _utilizationRate;
    }


    // keccak256(abi.encode(uint256(keccak256("erc7201:storage:RateStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RateStorageLocation = 0x4b11a1a855e13907564ebae8fe1aa8ed2d533bd727265f313e523a7cd7825f00;

    function _getRateStorage() private pure returns (RateStorageStruct storage $) {
        assembly {
            $.slot := RateStorageLocation
        }
    }

    /* Rate Methods */
    function getZeroBalanceFee() public view virtual returns (uint256) {
        RateStorageStruct storage $ = _getRateStorage();
        return $._zeroBalanceFee;

    }
    function getRewardsRate() public view virtual returns (uint256) {
        RateStorageStruct storage $ = _getRateStorage();
        return $._rewardsRate;
    }

    function getLenderPremium() public view virtual returns (uint256) {
        RateStorageStruct storage $ = _getRateStorage();
        return $._lenderPremium;
    }

    function getProtocolFee() public view virtual returns (uint256) {
        RateStorageStruct storage $ = _getRateStorage();
        return $._protocolFee;
    }

    function getUtilizationRate() public view virtual returns (uint256) {
        RateStorageStruct storage $ = _getRateStorage();
        return $._utilizationRate;
    }

    function setZeroBalanceFee(uint256 zeroBalanceFee) public onlyOwner {
        RateStorageStruct storage $ = _getRateStorage();
        $._zeroBalanceFee = zeroBalanceFee;
    }

    function setRewardsRate(uint256 rewardsRate) public onlyOwner {
        RateStorageStruct storage $ = _getRateStorage();
        $._rewardsRate = rewardsRate;
    }

    function setLenderPremium(uint256 lenderPremium) public onlyOwner {
        RateStorageStruct storage $ = _getRateStorage();
        $._lenderPremium = lenderPremium;
    }

    function setProtocolFee(uint256 protocolFee) public onlyOwner {
        RateStorageStruct storage $ = _getRateStorage();
        $._protocolFee = protocolFee;
    }
    
    function setUtilizationRate(uint256 utilizationRate) public onlyOwner {
        RateStorageStruct storage $ = _getRateStorage();
        $._utilizationRate = utilizationRate;
    }
}