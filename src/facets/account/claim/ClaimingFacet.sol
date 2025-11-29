// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PortfolioFactory} from "../../../accounts/PortfolioFactory.sol";
import {AccountConfigStorage} from "../../../storage/AccountConfigStorage.sol";
import {IVoter} from "../../../interfaces/IVoter.sol";
import {IVotingEscrow} from "../../../interfaces/IVotingEscrow.sol";
import {IRewardsDistributor} from "../../../interfaces/IRewardsDistributor.sol";
import {CollateralManager} from "../collateral/CollateralManager.sol";

/**
 * @title ClaimingFacet
 * @dev Facet that interfaces with voting escrow NFTs
 */
contract ClaimingFacet {
    PortfolioFactory public immutable _portfolioFactory;
    AccountConfigStorage public immutable _accountConfigStorage;
    IVotingEscrow public immutable _votingEscrow;
    IVoter public immutable _voter;
    IRewardsDistributor public immutable _rewardsDistributor;

    constructor(address portfolioFactory, address accountConfigStorage, address votingEscrow, address voter, address rewardsDistributor) {
        require(portfolioFactory != address(0));
        require(accountConfigStorage != address(0));
        _portfolioFactory = PortfolioFactory(portfolioFactory);
        _accountConfigStorage = AccountConfigStorage(accountConfigStorage);
        _votingEscrow = IVotingEscrow(votingEscrow);
        _voter = IVoter(voter);
        _rewardsDistributor = IRewardsDistributor(rewardsDistributor);
    }

    function claimFees(address[] calldata fees, address[][] calldata tokens, uint256 tokenId) external {
        _voter.claimFees(fees, tokens, tokenId);
    }

    function claimRebase(uint256 tokenId) external {
        uint256 claimable = _rewardsDistributor.claimable(tokenId);
        if (claimable > 0) {
            try _rewardsDistributor.claim(tokenId) {
            } catch {
            }
        }
        CollateralManager.updateLockedColleratal(tokenId);
    }

    function processRewards() external {
        require(_accountConfigStorage.isAuthorizedCaller(msg.sender));
        // TODO: Implement
    }
}

