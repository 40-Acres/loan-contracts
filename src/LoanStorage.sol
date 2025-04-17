// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ProtocolTimeLibrary} from "./libraries/ProtocolTimeLibrary.sol";


abstract contract LoanStorage is Ownable2StepUpgradeable {
    /// @custom:storage-location erc7201:storage:LoanStorage
    struct LoanStorageStruct {
        uint256 _totalWeights;
        uint256 _managedNft;
        mapping(address => bool) _isApprovedToken; // approved tokens for loan contract
        address _swapper;
        mapping(address => uint256) _userPayoffToken; // token a user pays off first
        mapping(address => bool) _userPayoffTokenOption; // if user wants to pay off specific token first
        mapping(uint256 => uint256) _totalWeightPerEpoch;
        mapping(address => address[]) _userPoolVotes; // pools user wants to vote on
        mapping(address => uint256[]) _userPoolWeights; // weights for pools user wants to vote on
        mapping(address => uint256) _userPoolChangeTime; // weights for pools user wants to vote on
    }


    // keccak256(abi.encode(uint256(keccak256("erc7201:storage:LoanStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LoanStorageLocation = 0x6dd8e034303aa35aaf3d00b596a4336c7daf449d21fe7bc9975d763227647b00;

    function _getLoanStorage() private pure returns (LoanStorageStruct storage $) {
        assembly {
            $.slot := LoanStorageLocation
        }
    }

    /* Rate Methods */

    /// @dev Get the total weight for the loan contract
    function getTotalWeight() public view virtual returns (uint256) {
        LoanStorageStruct storage $ = _getLoanStorage();
        return $._totalWeights;

    }

    /// @dev Add total weight for the loan contract
    function addTotalWeight(uint256 weights) internal  {
        LoanStorageStruct storage $ = _getLoanStorage();
        $._totalWeights += weights;
        $._totalWeightPerEpoch[ProtocolTimeLibrary.epochStart(block.timestamp)] = $._totalWeights;

    }

    /// @dev Subtract total weight for the loan contract
    function subTotalWeight(uint256 weights) internal {
        LoanStorageStruct storage $ = _getLoanStorage();
        $._totalWeights -= weights;
        $._totalWeightPerEpoch[ProtocolTimeLibrary.epochStart(block.timestamp)] = $._totalWeights;
    }

    /// @dev Set the managed NFT for the loan contract
    function setManagedNft(uint256 managedNft) onlyOwner public virtual {
        LoanStorageStruct storage $ = _getLoanStorage();
        $._managedNft = managedNft;
    }

    /// @dev Get the managed NFT for the loan contract
    function getManagedNft() internal view virtual returns (uint256) {
        LoanStorageStruct storage $ = _getLoanStorage();
        return $._managedNft;
    }

    /// @dev Check if the token is approved for the loan contract
    function isApprovedToken(address token) public view virtual returns (bool) {
        LoanStorageStruct storage $ = _getLoanStorage();
        return $._isApprovedToken[token];
    }
    /// @dev Set approved token for the loan contract
    function setApprovedToken(address token, bool approved) public onlyOwner virtual {
        LoanStorageStruct storage $ = _getLoanStorage();
        $._isApprovedToken[token] = approved;
    }

    /// @dev Get the swapper address for the loan contract
    function getSwapper() internal view virtual returns (address) {
        LoanStorageStruct storage $ = _getLoanStorage();
        return $._swapper;
    }

    /// @dev Set the swapper address for the loan contract
    function setSwapper(address swapper) public onlyOwner virtual {
        LoanStorageStruct storage $ = _getLoanStorage();
        $._swapper = swapper;
    }

    function _setUserPayoffToken(address user, uint256 token) internal {
        LoanStorageStruct storage $ = _getLoanStorage();
        $._userPayoffToken[user] = token;
    }

    function getUserPayoffToken(address user) public view virtual returns (uint256) {
        LoanStorageStruct storage $ = _getLoanStorage();
        return $._userPayoffToken[user];
    }

    function _setUserPayoffTokenOption(address user, bool option) internal  {
        LoanStorageStruct storage $ = _getLoanStorage();
        $._userPayoffTokenOption[user] = option;
    }

    function userUsesPayoffToken(address user) public view virtual returns (bool) {
        LoanStorageStruct storage $ = _getLoanStorage();
        return $._userPayoffTokenOption[user];
    }

    function _getTotalWeightPerEpoch(uint256 epoch) internal view virtual returns (uint256) {
        LoanStorageStruct storage $ = _getLoanStorage();
        return $._totalWeightPerEpoch[epoch];
    }

    function _setUserPoolVotes(address user, address[] calldata pools, uint256[] calldata weights) internal {
        LoanStorageStruct storage $ = _getLoanStorage();
        $._userPoolVotes[user] = pools;
        $._userPoolWeights[user] = weights;
        $._userPoolChangeTime[user] = block.timestamp;
    }

    function _getUserPoolVotes(address user) internal view virtual returns (address[] memory pools, uint256[] memory weights, uint256 time) {
        LoanStorageStruct storage $ = _getLoanStorage();
        return ($._userPoolVotes[user], $._userPoolWeights[user], $._userPoolChangeTime[user]);
    }

}