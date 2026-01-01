// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ProtocolTimeLibrary } from "./libraries/ProtocolTimeLibrary.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

contract DynamicFeesVault is Initializable, ERC4626Upgradeable, UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @custom:storage-location erc7201:openzeppelin.storage.DynamicFee
    struct DynamicFeeStorage {
        uint256 totalLoanedAssets; // total assets currently loaned out to users
        uint256 originationFeeBasisPoints; // basis points for the origination fee
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.DynamicFee")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DynamicFeeStorageLocation = 0x1fb3ee4230eab4d51787ea4fd7ea8e382ed9dd2d2f3a0098da879cf8bc614f00;

    function _getDynamicFeeStorage() private pure returns (DynamicFeeStorage storage $) {
        assembly {
            $.slot := DynamicFeeStorageLocation
        }
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address asset, address loan, string memory name, string memory symbol, address portfolioFactory) public initializer {
        __ERC4626_init(ERC20(asset));
        __ERC20_init(name, symbol);
        __UUPSUpgradeable_init();
        __Ownable2Step_init(msg.sender);
    }

    /**
     * @dev This function is used to authorize upgrades to the contract.
     *      It restricts the upgradeability to only the contract owner.
     * @param newImplementation The address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function totalAssets() public view override virtual returns (uint256) {
        return _asset.balanceOf(address(this)) + _getDynamicFeeStorage().totalLoanedAssets + rewardsAccrued;
    }

    function borrow(uint256 amount) public {
        _asset.transferFrom(msg.sender, address(this), amount);
        _getDynamicFeeStorage().totalLoanedAssets += amount;
    }

    function repay(uint256 amount) public {
        _asset.transferFrom(msg.sender, address(this), amount);
        _getDynamicFeeStorage().totalLoanedAssets -= amount;
    }

}