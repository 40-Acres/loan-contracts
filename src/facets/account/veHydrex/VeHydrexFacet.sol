// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {IHydrexVoter} from "../../../interfaces/IHydrexVoter.sol";
import {IHydrexVotingEscrow} from "../../../interfaces/IHydrexVotingEscrow.sol";
import {VotingConfig} from "../config/VotingConfig.sol";
import {ProtocolTimeLibrary} from "../../../libraries/ProtocolTimeLibrary.sol";
import {UserVotingConfig} from "../vote/UserVotingConfig.sol";
import {AccessControl} from "../utils/AccessControl.sol";
import {HydrexCollateralManager} from "./HydrexCollateralManager.sol";

/**
 * @title VeHydrexFacet
 * @dev Voting facet for Hydrex. The Hydrex Voter votes account-wide via
 *      vote(pools, weights) and auto-resets the prior epoch's ballot. The
 *      tokenId argument on this facet's methods is used only for per-tokenId
 *      collateral tracking; the on-chain ballot covers every veNFT the
 *      account currently holds, regardless of which tokenId was named.
 *
 *      Manual-vote state is per-ACCOUNT, not per-tokenId, since the Hydrex
 *      Voter is account-wide. UserVotingConfig.{set,get}VotingMode is keyed
 *      on tokenId=0 to mean "the account's manual-mode preference".
 *
 *      defaultVote is gated by a per-epoch rule: if the user has opted into
 *      manual mode (sticky flag, tokenId=0) AND the account has already voted
 *      in the current epoch (per Voter.lastVoted), the operator's default-vote
 *      is blocked. Each new epoch resets the gate naturally.
 *
 *      Note on mid-epoch weight changes: Hydrex's _vote computes the weight
 *      via getPastVotes(voter, epochStart), so weight that arrives mid-epoch
 *      (rebase claims, external arrivals) does NOT count toward the current
 *      epoch's vote and CANNOT be picked up by poke. It counts in the next
 *      epoch automatically when the new epoch-start snapshot is taken.
 */
contract VeHydrexFacet is AccessControl {
    PortfolioFactory public immutable _portfolioFactory;
    IHydrexVotingEscrow public immutable _votingEscrow;
    IHydrexVoter public immutable _voter;
    VotingConfig public immutable _votingConfig;

    error PoolNotApproved(address pool);
    error PoolsCannotBeEmpty();
    error NotAuthorized();

    event Voted(uint256 indexed tokenId, address[] pools, uint256[] weights, address indexed owner);
    event VotingModeSet(uint256 indexed tokenId, bool setToManualVoting, address indexed owner);

    constructor(address portfolioFactory, address votingConfigStorage, address votingEscrow, address voter) {
        require(portfolioFactory != address(0));
        require(votingEscrow != address(0), "Voting escrow address cannot be zero");
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _votingEscrow = IHydrexVotingEscrow(votingEscrow);
        _votingConfig = VotingConfig(votingConfigStorage);
        _voter = IHydrexVoter(voter);
    }

    function vote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights)
        public
        virtual
        onlyPortfolioManagerMulticall(_portfolioFactory)
    {
        _vote(tokenId, pools, weights);
        // Account-wide manual-mode flag; tokenId=0 is the account slot.
        UserVotingConfig.setVotingMode(0, true);
    }

    /// @notice One on-chain ballot covers all listed tokenIds
    function batchVote(uint256[] calldata tokenIds, address[] calldata pools, uint256[] calldata weights)
        external
        onlyPortfolioManagerMulticall(_portfolioFactory)
    {
        require(pools.length > 0, PoolsCannotBeEmpty());
        for (uint256 i = 0; i < pools.length; i++) {
            require(_votingConfig.isApprovedPool(pools[i]), PoolNotApproved(pools[i]));
        }
        _voter.vote(pools, weights);
    }

    /// @notice Operator-driven default vote. Blocked if the user has opted into
    ///         manual mode AND the account has already voted in the current epoch.
    ///         The next epoch resets the gate naturally via Voter.lastVoted.
    function defaultVote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights)
        external
        onlyAuthorizedCaller(_portfolioFactory)
    {
        require(_canDefaultVote(), "Account already voted this epoch");
        _vote(tokenId, pools, weights);
    }

    function _canDefaultVote() internal view returns (bool) {
        if (!UserVotingConfig.isManualVoting(0)) return true;
        uint256 lastVoted = _voter.lastVoted(address(this));
        if (lastVoted == 0) return true;
        return ProtocolTimeLibrary.epochStart(lastVoted) < ProtocolTimeLibrary.epochStart(block.timestamp);
    }

    function _vote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights) internal virtual {
        require(pools.length > 0, PoolsCannotBeEmpty());
        for (uint256 i = 0; i < pools.length; i++) {
            require(_votingConfig.isApprovedPool(pools[i]), PoolNotApproved(pools[i]));
        }
        address owner = _portfolioFactory.ownerOf(address(this));
        _voter.vote(pools, weights);
        _addLockedCollateral(tokenId);
        emit Voted(tokenId, pools, weights, owner);
    }

    function _addLockedCollateral(uint256 tokenId) internal virtual {
        HydrexCollateralManager.addLockedCollateral(
            address(_portfolioFactory.portfolioFactoryConfig()), tokenId, address(_votingEscrow)
        );
    }

    function isManualVoting(uint256 /* tokenId */) external view returns (bool) {
        // Account-wide flag stored at tokenId=0.
        return UserVotingConfig.isManualVoting(0);
    }

    function setVotingMode(uint256 /* tokenId */, bool setToManualVoting)
        external
        onlyPortfolioManagerMulticall(_portfolioFactory)
    {
        UserVotingConfig.setVotingMode(0, setToManualVoting);
        address owner = _portfolioFactory.ownerOf(address(this));
        emit VotingModeSet(0, setToManualVoting, owner);
    }

    function isElligibleForManualVoting(uint256 /* tokenId */) public pure returns (bool) {
        return true;
    }
}
