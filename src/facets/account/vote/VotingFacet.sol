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
import {UserVotingConfig} from "./UserVotingConfig.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";
/**
 * @title VotingFacet
 * @dev Facet that interfaces with voting
 */

contract VotingFacet is IVotingFacet, AccessControl {
    PortfolioFactory public immutable _portfolioFactory;
    PortfolioAccountConfig public immutable _portfolioAccountConfig;
    IVotingEscrow public immutable _votingEscrow;
    IVoter public immutable _voter;
    VotingConfig public immutable _votingConfig;

    error PoolNotApproved(address pool);
    error LaunchpadPoolNotApproved(address pool);
    error PoolsCannotBeEmpty();
    error NotAuthorized();

    constructor(address portfolioFactory, address portfolioAccountConfig, address votingConfigStorage, address votingEscrow, address voter) {
        require(portfolioFactory != address(0));
        require(portfolioAccountConfig != address(0));
        require(votingEscrow != address(0), "Voting escrow address cannot be zero");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _portfolioAccountConfig = PortfolioAccountConfig(portfolioAccountConfig);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _votingConfig = VotingConfig(votingConfigStorage);
        _voter = IVoter(voter);
    }

    function vote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights) virtual public  onlyPortfolioManagerMulticall(_portfolioFactory) {
        // ensure collateral is added when voting
        _vote(tokenId, pools, weights);
        // set user to manual voting mode
        UserVotingConfig.setVotingMode(tokenId, true);
    }

    function delegateVote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights) external {
        require(pools.length > 0, PoolsCannotBeEmpty());
        require(msg.sender == UserVotingConfig.getDelegatedVoter(tokenId), NotAuthorized());
        for(uint256 i = 0; i < pools.length; i++) {
            require(_votingConfig.isApprovedPool(pools[i]), PoolNotApproved(pools[i]));
        }
        _voter.vote(tokenId, pools, weights);
    }

    function defaultVote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights) external onlyAuthorizedCaller(_portfolioFactory) {
        // if user did not vote last epoch, set user to automatic voting mode
        uint256 lastVoted = IVoter(address(_voter)).lastVoted(tokenId);
        if(lastVoted < ProtocolTimeLibrary.epochStart(block.timestamp) - 1 weeks) {
            UserVotingConfig.setVotingMode(tokenId, false);
        }

        // if user is in manual voting mode, revert
        require(!UserVotingConfig.isManualVoting(tokenId));

        // only default vote during voting timw window (1 hour prior to voting period end)
        require(block.timestamp >= ProtocolTimeLibrary.epochVoteEnd(block.timestamp) - 1 hours);

        _vote(tokenId, pools, weights);
    }

    function voteForLaunchpadToken(uint256 tokenId, address[] calldata pools, uint256[] calldata weights, bool receiveLaunchPadToken) external onlyPortfolioManagerMulticall(_portfolioFactory) {
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
        require(pools.length > 0, PoolsCannotBeEmpty());
        for(uint256 i = 0; i < pools.length; i++) {
            require(_votingConfig.isApprovedPool(pools[i]), PoolNotApproved(pools[i]));
        }
        _voter.vote(tokenId, pools, weights);
        CollateralManager.addLockedColleratal(tokenId, address(_votingEscrow));
    }

    function isManualVoting(uint256 tokenId) external view returns (bool) {
        // if user is not eligible for manual voting, they are forced into automatic mode
        if(!_isElligibleForManualVoting(tokenId)) {
            return false;
        }
        // if user is eligible for manual voting, check if they explicitly set it to manual mode
        return UserVotingConfig.isManualVoting(tokenId);
    }

    function getDelegatedVoter(uint256 tokenId) external view returns (address) {
        return UserVotingConfig.getDelegatedVoter(tokenId);
    }

    function setVotingMode(uint256 tokenId, bool setToManualVoting) external onlyPortfolioManagerMulticall(_portfolioFactory) {
        if(setToManualVoting) {
            require(_isElligibleForManualVoting(tokenId));
        }
        UserVotingConfig.setVotingMode(tokenId, setToManualVoting);
    }

    function _isElligibleForManualVoting(uint256 tokenId) internal view returns (bool) {
        uint256 lastVoted = IVoter(address(_voter)).lastVoted(tokenId);
        // if token has not voted within the contract, they are not eligible for manual voting
        if(lastVoted < CollateralManager.getOriginTimestamp(tokenId) || CollateralManager.getOriginTimestamp(tokenId) == 0) {
            return false;
        }

        // if user missed a week, they are not eligible for manual voting
        if(ProtocolTimeLibrary.epochStart(lastVoted) < ProtocolTimeLibrary.epochStart(block.timestamp) - 1 weeks) {
            return false;
        }
        
        return true;
    }
}