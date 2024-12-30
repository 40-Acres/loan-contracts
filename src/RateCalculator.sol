// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.27;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

interface IOwnable {
    function owner() external view returns (address);
}

contract RateCalculator is Ownable {
    uint256 public protocolFee = 500; // 5%
    uint256 public lenderPremium = 2000 ; // 20%
    address public _loanContract;

    constructor(address loan) Ownable(msg.sender) {
        _loanContract = loan;
        transferOwnership(IOwnable(loan).owner());
    }

    function setInterestRate(uint256 _protocolFee, uint256 _lenderPremium) onlyOwner  public {
        protocolFee = _protocolFee;
        lenderPremium = _lenderPremium;
    }

    function getInterestRate() public view returns (uint256, uint256) {
        return (protocolFee, lenderPremium);
    }


    function confirm() public {
        require(msg.sender == _loanContract, "Only loan contract can call this function");
    }
    
}