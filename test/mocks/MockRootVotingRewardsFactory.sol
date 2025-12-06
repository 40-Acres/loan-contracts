// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IRootVotingRewardsFactory} from "../../src/interfaces/IRootVotingRewardsFactory.sol";

/**
 * @title MockRootVotingRewardsFactory
 * @dev Mock implementation of IRootVotingRewardsFactory for testing
 */
contract MockRootVotingRewardsFactory is IRootVotingRewardsFactory {
    address public override bridge;
    mapping(address => mapping(uint256 => address)) public override recipient;

    constructor() {
        bridge = address(0x1234567890123456789012345678901234567890); // Mock bridge address
    }

    function setRecipient(uint256 _chainid, address _recipient) external override {
        recipient[msg.sender][_chainid] = _recipient;
        emit RecipientSet(msg.sender, _chainid, _recipient);
    }

    function createRewards(address _forwarder, address[] memory _rewards)
        external
        pure
        override
        returns (address feesVotingReward, address incentiveVotingReward)
    {
        // Mock implementation - return zero addresses
        return (address(0), address(0));
    }
}

