// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title IMigrationFacet
 * @dev Interface for the MigrationFacet contract
 */
interface IMigrationFacet {
    function migrate(uint256 tokenId, uint256 unpaidFees) external;
}