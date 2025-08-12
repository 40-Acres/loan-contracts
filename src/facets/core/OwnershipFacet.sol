// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../interfaces/IERC173.sol";
import "../../libraries/LibDiamond.sol";

/**
 * @title OwnershipFacet
 * @dev Implementation of the IERC173 interface
 */
contract OwnershipFacet is IERC173 {
    /// @notice Get the address of the owner
    /// @return owner_ The address of the owner
    function owner() external view override returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }

    /// @notice Set the address of the new owner of the contract
    /// @dev Set _newOwner to address(0) to renounce any ownership
    /// @param _newOwner The address of the new owner of the contract
    function transferOwnership(address _newOwner) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setContractOwner(_newOwner);
    }
}
