// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../interfaces/IERC173.sol";
import "../../libraries/LibDiamond.sol";

/**
 * @title OwnershipFacet
 * @dev IERC173-compatible ownership with 2-step handover (Ownable2Step-style)
 */
contract OwnershipFacet is IERC173 {
    // ============ Storage ==========
    struct OwnershipFacetStorage {
        address pendingOwner;
    }

    // keccak256("diamond.ownership.facet.storage")
    bytes32 private constant OWNERSHIP_FACET_STORAGE_POSITION =
        0x2d7b6e159e2cb36244d33fa22a244d9ab8a35639369d2de4209a2bcc4f090b7d;

    function _ownershipFacetStorage() private pure returns (OwnershipFacetStorage storage s) {
        bytes32 slot = OWNERSHIP_FACET_STORAGE_POSITION;
        assembly {
            s.slot := slot
        }
    }

    // ============ Events ==========
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    // ============ Views ==========
    function owner() external view override returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }

    function pendingOwner() external view returns (address) {
        return _ownershipFacetStorage().pendingOwner;
    }

    // ============ Mutations ==========
    /// @notice Initiate ownership transfer to `_newOwner` (2-step)
    /// @dev Setting `_newOwner` to address(0) cancels any pending transfer (mirrors OZ Ownable2Step).
    function transferOwnership(address _newOwner) external override {
        LibDiamond.enforceIsContractOwner();
        OwnershipFacetStorage storage s = _ownershipFacetStorage();
        s.pendingOwner = _newOwner;
        emit OwnershipTransferStarted(LibDiamond.contractOwner(), _newOwner);
    }

    /// @notice Accept ownership transfer (called by pending owner)
    function acceptOwnership() external {
        OwnershipFacetStorage storage s = _ownershipFacetStorage();
        require(msg.sender == s.pendingOwner, "Ownership: not pending owner");
        s.pendingOwner = address(0);
        LibDiamond.setContractOwner(msg.sender);
    }

    /// @notice Renounce ownership explicitly by transferring to address(0)
    /// @dev Matches OZ semantics where transferOwnership(0) cancels pending owner and owner can set to zero via this call.
    function renounceOwnership() external {
        LibDiamond.enforceIsContractOwner();
        // Clear any staged transfer and set owner to zero address
        _ownershipFacetStorage().pendingOwner = address(0);
        LibDiamond.setContractOwner(address(0));
    }
}
