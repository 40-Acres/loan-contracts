// SPDX-License-Identifier: SEE LICENSE IN LICENSE

pragma solidity ^0.8.27;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";


contract Vault is ERC4626 {
    ERC20 public _asset;
    address public _loanContract;
    uint256 public _activeLoanAssets;

    constructor(ERC20 asset, address loan) ERC4626(asset) ERC20("Vault", "VAULT")  {
        _asset = asset;
        _loanContract = loan;
    }

    modifier onlyLoanContract() {
        require(msg.sender == _loanContract, "Only loan contract can call this function");
        _;
    }

    function totalAssets() public view override returns (uint256) {
        return _asset.balanceOf(address(this)) + _activeLoanAssets;
    }

    function transferToLoan(uint256 amount) external onlyLoanContract {
        _asset.transfer(_loanContract, amount);
        _activeLoanAssets += amount;
    }

    function transferFromLoan(uint256 amount) external onlyLoanContract {
        _asset.transferFrom(_loanContract, address(this), amount);
        _activeLoanAssets -= amount;
    }
}