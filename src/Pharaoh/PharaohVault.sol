// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Vault as VaultV2 } from "../VaultV2.sol";
import "../interfaces/ILoan.sol";


contract Vault is VaultV2 {
    function totalAssets() public view override returns (uint256) {
        return _asset.balanceOf(address(this)) + _loanContract.activeAssets(); 
    }

    function approveContract(address contractAddress) public onlyOwner {
        ERC20(address(_asset)).approve(contractAddress, type(uint256).max);
    }
}