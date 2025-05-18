// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Vault as VaultV2 } from "../VaultV2.sol";
import "../interfaces/ILoan.sol";


contract Vault is VaultV2 {
    function epochRewardsLocked() public view override returns (uint256) {
        return 0; // rewards come in over time over the epoch, so we don't need to lock any rewards
    }

    function totalAssets() public view override returns (uint256) {
        return _asset.balanceOf(address(this)) + _loanContract.activeAssets(); 
    }
}