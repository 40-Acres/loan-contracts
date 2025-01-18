// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.27;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

interface IOwnable {
    function owner() external view returns (address);
}

contract RateCalculator is Ownable {
    uint256 public protocolFee = 500; // 5%
    uint256 public lenderPremium = 2000 ; // 20%
    uint256 public rewardsRate = 113; // .0113%
    address public loanContract;

    constructor(address _loan) Ownable(msg.sender) {
        loanContract = _loan;
        transferOwnership(IOwnable(_loan).owner());
    }

    function setInterestRate(uint256 _protocolFee, uint256 _lenderPremium) onlyOwner  public {
        protocolFee = _protocolFee;
        lenderPremium = _lenderPremium;
    }

    function setRewardsRate(uint256 _rewardsRate) onlyOwner  public {
        rewardsRate = _rewardsRate;
    }

    function getInterestRate() public view returns (uint256, uint256) {
        return (protocolFee, lenderPremium);
    }

    function getRewardsRate() public view returns (uint256) {
        return rewardsRate;
    }

    function confirm() external  view {
        require(msg.sender == loanContract, "Only loan contract can call this function");
    }
    
    
}