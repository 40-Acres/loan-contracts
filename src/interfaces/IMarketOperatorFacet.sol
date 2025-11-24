// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IMarketOperatorFacet {
    event OperatorApproved(address indexed owner, address indexed operator, bool approved);
    function setOperatorApproval(address operator, bool approved) external;
}


