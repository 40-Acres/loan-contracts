// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {FacetRegistry} from "./FacetRegistry.sol";

/**
 * @title FortyAcresPortfolioAccount
 * @dev Account contract that references centralized facets
 */
contract FortyAcresPortfolioAccount {
    FacetRegistry public immutable facetRegistry;

    /// @dev ERC-7201 storage slot for reentrancy guard
    bytes32 private constant _REENTRANCY_GUARD_SLOT = keccak256("fortyacres.reentrancy.guard");
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    event AccountCreated(address indexed portfolio, address indexed owner);

    constructor(address _facetRegistry) {
        require(_facetRegistry != address(0));

        facetRegistry = FacetRegistry(_facetRegistry);
        
        // Initialize reentrancy guard
        bytes32 slot = _REENTRANCY_GUARD_SLOT;
        assembly { sstore(slot, 1) }

        emit AccountCreated(address(this), msg.sender);
    }
    
    /**
     * @dev Multicall function that allows batching multiple function calls
     * @param data Array of encoded function calls
     * @return results Array of return data from each function call
     */
    function multicall(bytes[] calldata data) external returns (bytes[] memory results) {
        bytes32 slot = _REENTRANCY_GUARD_SLOT;
        uint256 status;
        assembly { status := sload(slot) }
        require(status != _ENTERED, "ReentrancyGuard: reentrant call");
        assembly { sstore(slot, 2) }

        results = new bytes[](data.length);

        for (uint256 i = 0; i < data.length; i++) {
            bytes4 selector = bytes4(data[i][:4]);
            address facet = _getFacetForSelector(selector);
            require(facet != address(0));

            (bool success, bytes memory result) = facet.delegatecall(data[i]);
            require(success);
            results[i] = result;
        }

        assembly { sstore(slot, 1) }
        return results;
    }
    
    /**
     * @dev Get facet for a function selector from centralized registry
     */
    function _getFacetForSelector(bytes4 selector) internal view returns (address) {
        return facetRegistry.getFacetForSelector(selector);
    }

    fallback() external payable {
        address facet = _getFacetForSelector(msg.sig);
        require(facet != address(0));

        bytes32 guardSlot = _REENTRANCY_GUARD_SLOT;

        assembly {
            // Check reentrancy guard (read-only): prevents re-entry via fallback while multicall is active.
            // We only read (sload) here — no sstore — so this works under STATICCALL for view functions.
            // The multicall() function sets the guard to 2 and resets it, so any callback during
            // multicall will see status==2 and revert. Direct fallback calls see status==1 and proceed.
            if iszero(eq(caller(), address())) {
                let status := sload(guardSlot)
                if eq(status, 2) { revert(0, 0) }
            }

            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())

            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}