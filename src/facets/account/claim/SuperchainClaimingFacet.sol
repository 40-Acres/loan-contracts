// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IReward} from "../../../interfaces/IReward.sol";
import {IRootVotingRewardsFactory} from "../../../interfaces/IRootVotingRewardsFactory.sol";
import {IRootPool} from "../../../interfaces/IRootPool.sol";

/**
 * @title SuperchainClaimingFacet
 * @dev Claims fees/incentives from superchain root reward contracts directly.
 */
contract SuperchainClaimingFacet {
    address public constant ROOT_VOTING_REWARDS_FACTORY = 0x7dc9fd82f91B36F416A89f5478375e4a79f4Fb2F;

    function claimSuperchainRewards(
        address[] calldata _rewardContracts,
        address[][] calldata _tokens,
        uint256 _tokenId,
        address _pool
    ) external {
        require(_rewardContracts.length == _tokens.length, "Length mismatch");

        uint256 chainId = IRootPool(_pool).chainid();
        address current = IRootVotingRewardsFactory(ROOT_VOTING_REWARDS_FACTORY).recipient(address(this), chainId);
        if (current != address(this)) {
            IRootVotingRewardsFactory(ROOT_VOTING_REWARDS_FACTORY).setRecipient(chainId, address(this));
        }
        for (uint256 i = 0; i < _rewardContracts.length; i++) {
            IReward(_rewardContracts[i]).getReward(_tokenId, _tokens[i]);
        }
    }
}
