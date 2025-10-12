// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Vault as VaultV2 } from "../VaultV2.sol";
import {ILoan} from "../interfaces/ILoan.sol";


contract Vault is VaultV2 {
    function totalAssets() public view override returns (uint256) {
        return _asset.balanceOf(address(this)) + _loanContract.activeAssets(); 
    }

    function setLoanContract(address newLoanContract) public onlyOwner {
        require(ILoan(newLoanContract).activeAssets() == ILoan(_loanContract).activeAssets());
        ERC20(address(_asset)).approve(address(_loanContract), 0);
        _loanContract = ILoan(newLoanContract);
        ERC20(address(_asset)).approve(newLoanContract, type(uint256).max);
    }
}