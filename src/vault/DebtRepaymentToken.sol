// // Debt Repayment Token is an ERC4626 token that represents the debt of a loan

// // SPDX-License-Identifier: MIT

// pragma solidity ^0.8.27;

// import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
// import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// contract DebtRepaymentToken is ERC4626 {
//     constructor(address asset, address loan, string memory name, string memory symbol) ERC4626(ERC20(asset)) ERC20(name, symbol) {

//     }


//     // remove transfer functionality   
//     function transfer(address to, uint256 amount) public override returns (bool) {
//         revert("Transfer not allowed");
//     }

//     function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
//         revert("Transfer not allowed");
//     }

//     function approve(address spender, uint256 amount) public override returns (bool) {
//         revert("Approve not allowed");
//     }

//     function allowance(address owner, address spender) public view override returns (uint256) {
//         revert("Allowance not allowed");
//     }
    
// }

