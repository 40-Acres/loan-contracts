// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {PortfolioAccountConfig} from "../config/PortfolioAccountConfig.sol";
import {IVoter} from "../../../interfaces/IVoter.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {IVotingFacet} from "./interfaces/IVotingFacet.sol";
import {VotingConfig} from "../config/VotingConfig.sol";
import {UserClaimingConfig} from "../claim/UserClaimingConfig.sol";
import {ProtocolTimeLibrary} from "../../../libraries/ProtocolTimeLibrary.sol";

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
    error LaunchpadPoolNotApproved(address pool);
    error PoolsCannotBeEmpty();

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
        _vote(tokenId, pools, weights);
    }

    function voteForLaunchpadToken(uint256 tokenId, address[] calldata pools, uint256[] calldata weights, bool receiveLaunchPadToken) external {
        for(uint256 i = 0; i < pools.length; i++) {
            address launchpadToken = _votingConfig.getLaunchpadPoolTokenForEpoch(ProtocolTimeLibrary.epochNext(block.timestamp), pools[i]);
            if(launchpadToken != address(0)) {
                UserClaimingConfig.setLaunchPadTokenForNextEpoch(tokenId, launchpadToken);
                UserClaimingConfig.setReceiveLaunchPadTokenForNextEpoch(receiveLaunchPadToken);
            }
        }
        _vote(tokenId, pools, weights);
    }

    function _vote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights) internal virtual {
        require(msg.sender == _portfolioFactory.ownerOf(address(this)));
        require(pools.length > 0, PoolsCannotBeEmpty());
        for(uint256 i = 0; i < pools.length; i++) {
            require(_votingConfig.isApprovedPool(pools[i]), PoolNotApproved(pools[i]));
        }
        _voter.vote(tokenId, pools, weights);
    }
}

