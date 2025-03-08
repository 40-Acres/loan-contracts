// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./interfaces/ILoan.sol";
import { ProtocolTimeLibrary } from "./libraries/ProtocolTimeLibrary.sol";


contract Vault is ERC4626 {
    ERC20 public _asset;
    ILoan public _loanContract;

    constructor(address asset, address loan) ERC4626(ERC20(asset)) ERC20("Vault", "VAULT")  {
        _asset = ERC20(asset);
        _loanContract = ILoan(loan);
        _asset.approve(loan, type(uint256).max);
    }

    modifier onlyLoanContract() {
        require(msg.sender == address(_loanContract), "Only loan contract can call this function");
        _;
    }

    function epochRewardsLocked() public view returns (uint256) {
        uint256 epochTimeRemaining = ProtocolTimeLibrary.epochNext(block.timestamp) - block.timestamp;
        uint256 epochRewards = _loanContract.lastEpochReward();

        // percentage of epoch rewards based on time elapsed
        return  epochTimeRemaining * epochRewards / ProtocolTimeLibrary.WEEK;
    }

    function totalAssets() public view override returns (uint256) {
        return _asset.balanceOf(address(this)) + _loanContract.activeAssets() - epochRewardsLocked(); }

}