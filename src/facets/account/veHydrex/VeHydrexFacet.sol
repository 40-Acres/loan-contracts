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
        UserVotingConfig.setVotingMode(tokenId, true);
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

    /// @notice Operator-driven default vote. Allowed across the whole epoch because
    ///         Hydrex's Voter.vote auto-resets the prior ballot, so a later manual
    ///         vote in the same epoch can freely override the default.
    function defaultVote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights)
        external
        onlyAuthorizedCaller(_portfolioFactory)
    {
        if (!isElligibleForManualVoting(tokenId) && UserVotingConfig.isManualVoting(tokenId)) {
            UserVotingConfig.setVotingMode(tokenId, false);
        }

        require(!UserVotingConfig.isManualVoting(tokenId));

        _vote(tokenId, pools, weights);
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

    function _getOriginTimestamp(uint256 tokenId) internal view virtual returns (uint256) {
        return HydrexCollateralManager.getOriginTimestamp(tokenId);
    }

    function isManualVoting(uint256 tokenId) external view returns (bool) {
        if (!isElligibleForManualVoting(tokenId)) {
            return false;
        }
        return UserVotingConfig.isManualVoting(tokenId);
    }

    function setVotingMode(uint256 tokenId, bool setToManualVoting)
        external
        onlyPortfolioManagerMulticall(_portfolioFactory)
    {
        if (setToManualVoting) {
            require(isElligibleForManualVoting(tokenId));
        }
        UserVotingConfig.setVotingMode(tokenId, setToManualVoting);
        address owner = _portfolioFactory.ownerOf(address(this));
        emit VotingModeSet(tokenId, setToManualVoting, owner);
    }

    function isElligibleForManualVoting(uint256 tokenId) public view returns (bool) {
        // Hydrex Voter.lastVoted is per-account, not per-tokenId. Eligibility is account-wide;
        // the tokenId argument here only drives the origin-timestamp gate.
        //
        // Hydrex does not carry votes across epochs: weightsPerEpoch is keyed on the
        // current epoch and zero-initialized each flip. Manual mode therefore requires
        // an active vote in the CURRENT epoch.
        uint256 lastVoted = _voter.lastVoted(address(this));
        if (lastVoted < _getOriginTimestamp(tokenId) || _getOriginTimestamp(tokenId) == 0) {
            return false;
        }
        if (ProtocolTimeLibrary.epochStart(lastVoted) < ProtocolTimeLibrary.epochStart(block.timestamp)) {
            return false;
        }
        return true;
    }
}
