// // SPDX-License-Identifier: MIT

// pragma solidity ^0.8.27;

// import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
// import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
// import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
// import { ProtocolTimeLibrary } from "./libraries/ProtocolTimeLibrary.sol";
// import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// import {DebtRepaymentToken} from "./DebtRepaymentToken.sol";

// contract Vault is Initializable, ERC4626Upgradeable, UUPSUpgradeable {
//     ERC20 public _asset;
//     ILoan public _loanContract;
//     DebtRepaymentToken public _debtRepaymentToken;

//     constructor() {
//         _disableInitializers();
//     }

//     function initialize(address asset, address loan, string memory name, string memory symbol) public initializer {
//         __ERC4626_init(ERC20(asset));
//         __ERC20_init(name, symbol);
//         __UUPSUpgradeable_init();
//         _asset = ERC20(asset);
//         _loanContract = ILoan(loan);
//         _asset.approve(loan, type(uint256).max);
//         _debtRepaymentToken = new DebtRepaymentToken(asset, loan, name, symbol);
//     }

//     /**
//      * @dev This function is used to authorize upgrades to the contract.
//      *      It restricts the upgradeability to only the contract owner.
//      * @param newImplementation The address of the new implementation contract.
//      */
//     function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
//     }

//     function epochRewardsLocked() public view virtual returns (uint256) {
//         uint256 epochTimeRemaining = ProtocolTimeLibrary.epochNext(block.timestamp) - block.timestamp;
//         uint256 epochRewards = _loanContract.lastEpochReward();

//         // percentage of epoch rewards based on time elapsed
//         return  epochTimeRemaining * epochRewards / ProtocolTimeLibrary.WEEK;
//     }

//     function totalAssets() public view override virtual returns (uint256) {
//         return _asset.balanceOf(address(this)) + _loanContract.activeAssets() - epochRewardsLocked(); 
//     }

//     /* Modifiers */
//     // only the owner of the loan contract can call this function
//     modifier onlyOwner() {
//         require(msg.sender == _loanContract.owner());
//         _;
//     }
// }