// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/**
 * @title IVotingFacet
 * @dev Interface for voting facet
 */
interface IVotingFacet {
    function vote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights) external;
    function setDelegatedVoter(uint256 tokenId, address delegatedVoter) external;
}