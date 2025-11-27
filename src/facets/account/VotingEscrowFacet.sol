// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../accounts/PortfolioFactory.sol";
import {AccountConfigStorage} from "../../storage/AccountConfigStorage.sol";
import {IVoter} from "../../interfaces/IVoter.sol";
import {IVotingEscrow} from "../../interfaces/IVotingEscrow.sol";

/**
 * @title VotingEscrowFacet
 * @dev Facet that interfaces with voting escrow NFTs
 */
contract VotingEscrowFacet {
    PortfolioFactory public immutable _portfolioFactory;
    AccountConfigStorage public immutable _accountConfigStorage;
    IVotingEscrow public _votingEscrow;
    IVoter public immutable _voter;

    constructor(address portfolioFactory, address accountConfigStorage, address votingEscrow, address voter) {
        require(portfolioFactory != address(0));
        require(accountConfigStorage != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _accountConfigStorage = AccountConfigStorage(accountConfigStorage);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _voter = IVoter(voter);
    }

    function claimFees(address[] calldata fees, address[][] calldata tokens, uint256 tokenId) external {
        _voter.claimFees(fees, tokens, tokenId);
    }

    function claimRebases(uint256 tokenId) external {
        // TODO: Implement
    }

    function processRewards(uint256 tokenId, uint256 rewardsAmount) external {
        // TODO: Implement
    }
}

