// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IVoter} from "../../../interfaces/IVoter.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {VotingFacet} from "./VotingFacet.sol";
import {SuperchainVotingConfig} from "../config/SuperchainVotingConfig.sol";
import {IRootVotingRewardsFactory} from "../../../interfaces/IRootVotingRewardsFactory.sol";

/**
 * @title SuperchainVotingFacet
 * @dev Facet that interfaces with superchain voting.
 *      Requires veNFTs to have a minimum locked balance per superchain pool voted on,
 *      ensuring the token generates enough rewards to cover cross-chain claim costs.
 */
contract SuperchainVotingFacet is VotingFacet {
    address public immutable ROOT_VOTING_REWARDS_FACTORY = address(0x7dc9fd82f91B36F416A89f5478375e4a79f4Fb2F);

    SuperchainVotingConfig public immutable _superchainVotingConfig;

    error InsufficientLockedBalance();

    constructor(address portfolioFactory, address votingConfig, address votingEscrow, address voter)
        VotingFacet(portfolioFactory, votingConfig, votingEscrow, voter)
    {
        _superchainVotingConfig = SuperchainVotingConfig(address(votingConfig));
    }

    function vote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights) public override onlyPortfolioManagerMulticall(_portfolioFactory) {
        uint256 superchainPoolCount = 0;
        for(uint256 i = 0; i < pools.length; i++) {
            if(_superchainVotingConfig.isSuperchainPool(pools[i])) {
                superchainPoolCount++;
                uint256 chainId = _superchainVotingConfig.getSuperchainPoolChainId(pools[i]);
                address recipient = IRootVotingRewardsFactory(ROOT_VOTING_REWARDS_FACTORY).recipient(address(this), chainId);
                if(recipient != address(this)) {
                    IRootVotingRewardsFactory(ROOT_VOTING_REWARDS_FACTORY).setRecipient(chainId, address(this));
                }
            }
        }
        if(superchainPoolCount > 0) {
            _requireMinimumLockedBalance(tokenId, superchainPoolCount);
        }
        super.vote(tokenId, pools, weights);
    }

    function _requireMinimumLockedBalance(uint256 tokenId, uint256 numSuperchainPools) internal view {
        uint256 minimumPerPool = _superchainVotingConfig.getMinimumLockedBalancePerPool();
        require(minimumPerPool > 0);
        uint256 requiredBalance = minimumPerPool * numSuperchainPools;
        int128 lockedAmount = _votingEscrow.locked(tokenId).amount;
        require(lockedAmount > 0 && uint256(uint128(lockedAmount)) >= requiredBalance, InsufficientLockedBalance());
    }
}
