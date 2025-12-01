// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {IVoter} from "../../../interfaces/IVoter.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {IVotingFacet} from "./interfaces/IVotingFacet.sol";
import {VotingConfig} from "../config/VotingConfig.sol";

/**
 * @title VotingFacet
 * @dev Facet that interfaces with voting
 */

contract VotingFacet is IVotingFacet {
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    IVotingEscrow public _votingEscrow;
    IVoter public immutable _voter;
    VotingConfig public immutable _votingConfig;

    error PoolNotApproved(address pool);
    
    constructor(address portfolioFactory, address portfolioAccountConfig, address votingConfigStorage, address votingEscrow, address voter) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _votingConfig = VotingConfig(votingConfigStorage);
        _voter = IVoter(voter);
    }

    function vote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights) virtual external {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        _vote(tokenId, pools, weights);
    }

    function voteForLaunchpadToken(uint256 tokenId, address[] calldata pools, uint256[] calldata weights, address launchpadToken, bool receiveLaunchPadToken) external {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        _vote(tokenId, pools, weights);
        UserClaimingConfig.setLaunchPadTokenForNextEpoch(tokenId, launchpadToken);
        UserClaimingConfig.setReceiveLaunchPadTokenForNextEpoch(receiveLaunchPadToken);
    }

    function _vote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights) internal virtual {
        for(uint256 i = 0; i < pools.length; i++) {
            require(_votingConfig.isApprovedPool(pools[i]), PoolNotApproved(pools[i]));
        }
        _voter.vote(tokenId, pools, weights);
    }
}

